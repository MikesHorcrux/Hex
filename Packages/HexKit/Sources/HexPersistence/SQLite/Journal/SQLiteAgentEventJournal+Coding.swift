import Foundation
import HexCore

extension SQLiteAgentEventJournal: CodingWorkspaceStorage {
  public func codingBaseline(_ taskID: UUID) throws -> GitWorkspaceSnapshot? {
    let q = try requireConnection().prepare(
      "SELECT payload FROM coding_baselines WHERE task_id = ?")
    try q.bind(taskID.uuidString, at: 1)
    guard try q.step() == .row else { return nil }
    return try JSONDecoder().decode(
      GitWorkspaceSnapshot.self, from: q.columnBlob(at: 0, maximumBytes: 6 * 1_024 * 1_024))
  }
  public func saveCodingBaseline(_ snapshot: GitWorkspaceSnapshot, taskID: UUID) throws {
    let c = try requireConnection()
    try withImmediateOwnedTransaction(connection: c) {
      let bytes = try JSONEncoder().encode(snapshot)
      guard bytes.count <= 6 * 1_024 * 1_024 else { throw ProcessSessionError.capacity }
      let q = try c.prepare(
        "INSERT INTO coding_baselines VALUES (?, ?) ON CONFLICT(task_id) DO NOTHING")
      try q.bind(taskID.uuidString, at: 1)
      try q.bind(bytes, at: 2)
      _ = try q.step()
      try validatePhysicalDatabaseSize(connection: c)
    }
  }
  public func codingPatch(_ id: String) throws -> WorkspacePatchReceipt? {
    let q = try requireConnection().prepare("SELECT payload FROM coding_patches WHERE id = ?")
    try q.bind(id, at: 1)
    guard try q.step() == .row else { return nil }
    return try JSONDecoder().decode(
      WorkspacePatchReceipt.self, from: q.columnBlob(at: 0, maximumBytes: 256 * 1_024))
  }
  public func saveCodingPatch(_ receipt: WorkspacePatchReceipt) throws {
    let c = try requireConnection()
    try withImmediateOwnedTransaction(connection: c) {
      let bytes = try JSONEncoder().encode(receipt)
      guard bytes.count <= 256 * 1_024, receipt.id.utf8.count <= 512, receipt.files.count <= 32
      else { throw ProcessSessionError.capacity }
      if let old = try codingPatch(receipt.id) {
        guard old.scope == receipt.scope, old.digest == receipt.digest,
          old.state == "pending" || (old.state == "partial" && receipt.state == "reconciled")
            || old == receipt
        else {
          throw ProcessSessionError.operationConflict
        }
      } else {
        guard try codingPatches(receipt.scope.taskID).count < 100 else {
          throw ProcessSessionError.capacity
        }
      }
      let q = try c.prepare(
        "INSERT INTO coding_patches VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET state=excluded.state, committed=excluded.committed, payload=excluded.payload"
      )
      try q.bind(receipt.id, at: 1)
      try q.bind(receipt.scope.taskID.uuidString, at: 2)
      try q.bind(receipt.state, at: 3)
      try q.bind(Int64(receipt.files.contains { $0.state == "applied" } ? 1 : 0), at: 4)
      try q.bind(bytes, at: 5)
      _ = try q.step()
      try validatePhysicalDatabaseSize(connection: c)
    }
  }
  public func codingPatches(_ taskID: UUID) throws -> [WorkspacePatchReceipt] {
    let q = try requireConnection().prepare(
      "SELECT payload FROM coding_patches WHERE task_id = ? ORDER BY rowid LIMIT 100")
    try q.bind(taskID.uuidString, at: 1)
    var result: [WorkspacePatchReceipt] = []
    while try q.step() == .row {
      result.append(
        try JSONDecoder().decode(
          WorkspacePatchReceipt.self, from: q.columnBlob(at: 0, maximumBytes: 256 * 1_024)))
    }
    return result
  }
  public func codingGeneration(_ taskID: UUID) throws -> Int64 {
    let patches = try codingPatches(taskID)
    guard patches.allSatisfy({ $0.state == "completed" || $0.state == "reconciled" }) else {
      throw ProcessSessionError.inputUncertain
    }
    return Int64(
      patches.filter {
        $0.files.contains {
          ["applied", "observed_after"].contains($0.state) && $0.before?.sha256 != $0.after?.sha256
        }
      }.count)
  }
}
