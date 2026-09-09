import Foundation
import HexCore

extension SQLiteAgentEventJournal: ProcessSessionStorage {
  public func processScope(for runID: AgentRunID, workspace: URL) throws -> ProcessSessionScope {
    let c = try requireConnection()
    let q = try c.prepare(
      """
      SELECT a.task_id, t.conversation_id FROM agent_task_attempts a
      JOIN conversation_tasks t ON t.task_id = a.task_id WHERE a.run_id = ?
      """)
    try q.bind(runID.rawValue.uuidString, at: 1)
    guard try q.step() == .row,
      let task = UUID(uuidString: try q.columnText(at: 0, maximumBytes: 36)),
      let conversation = UUID(uuidString: try q.columnText(at: 1, maximumBytes: 36))
    else { throw ProcessSessionError.unauthorized }
    guard let current = try readTask(task), current.runID == runID, current.phase == .running,
      current.attemptPending
    else { throw ProcessSessionError.unauthorized }
    return ProcessSessionScope(conversationID: conversation, taskID: task, workspace: workspace)
  }

  public func processSession(_ id: UUID) throws -> ProcessSessionRecord? {
    let q = try requireConnection().prepare("SELECT payload FROM process_sessions WHERE id = ?")
    try q.bind(id.uuidString, at: 1)
    guard try q.step() == .row else { return nil }
    return try JSONDecoder().decode(
      ProcessSessionRecord.self, from: q.columnBlob(at: 0, maximumBytes: 128 * 1_024))
  }

  public func processSessions(conversationID: UUID?, before: UUID?, limit: Int) throws
    -> [ProcessSessionRecord]
  {
    guard (1...100).contains(limit) else { throw ProcessSessionError.invalidRequest }
    let q = try requireConnection().prepare(
      """
      SELECT payload FROM process_sessions WHERE (? = '' OR conversation_id = ?)
      AND (? = '' OR rowid < (SELECT rowid FROM process_sessions WHERE id = ?))
      ORDER BY rowid DESC LIMIT ?
      """)
    for (i, s) in [
      conversationID?.uuidString ?? "", conversationID?.uuidString ?? "",
      before?.uuidString ?? "", before?.uuidString ?? "",
    ].enumerated() { try q.bind(s, at: Int32(i + 1)) }
    try q.bind(Int64(limit), at: 5)
    var rows: [ProcessSessionRecord] = []
    while try q.step() == .row {
      rows.append(
        try JSONDecoder().decode(
          ProcessSessionRecord.self, from: q.columnBlob(at: 0, maximumBytes: 128 * 1_024)))
    }
    return rows
  }

  public func saveProcessSession(_ input: ProcessSessionRecord) throws -> ProcessSessionRecord {
    let c = try requireConnection()
    return try withImmediateOwnedTransaction(connection: c) {
      let old = try processSession(input.id)
      guard input.revision == (old?.revision ?? 0), input.revision < Int64.max,
        old == nil || (old?.scope == input.scope && old?.epoch == input.epoch)
      else { throw ProcessSessionError.revisionConflict }
      var record = input
      record.revision += 1
      let payload = try JSONEncoder().encode(record)
      guard payload.count <= 128 * 1_024 else { throw ProcessSessionError.invalidRequest }
      let q = try c.prepare(
        """
        INSERT INTO process_sessions VALUES (?, ?, ?, ?) ON CONFLICT(id)
        DO UPDATE SET revision = excluded.revision, payload = excluded.payload
        """)
      try q.bind(record.id.uuidString, at: 1)
      try q.bind(record.scope.conversationID.uuidString, at: 2)
      try q.bind(record.revision, at: 3)
      try q.bind(payload, at: 4)
      _ = try q.step()
      try validatePhysicalDatabaseSize(connection: c)
      return record
    }
  }

  public func processOperation(_ id: String) throws -> ProcessSessionOperation? {
    let q = try requireConnection().prepare("SELECT payload FROM process_operations WHERE id = ?")
    try q.bind(id, at: 1)
    guard try q.step() == .row else { return nil }
    return try JSONDecoder().decode(
      ProcessSessionOperation.self, from: q.columnBlob(at: 0, maximumBytes: 4_096))
  }

  public func saveProcessOperation(_ op: ProcessSessionOperation) throws {
    let c = try requireConnection()
    try withImmediateOwnedTransaction(connection: c) {
      if let old = try processOperation(op.id) {
        guard old.digest == op.digest, old.sessionID == op.sessionID, old.sequence == op.sequence,
          old.action == op.action, old.state == "pending" || old == op
        else { throw ProcessSessionError.operationConflict }
      }
      let payload = try JSONEncoder().encode(op)
      guard payload.count <= 4_096, op.id.utf8.count <= 512 else {
        throw ProcessSessionError.invalidRequest
      }
      let q = try c.prepare(
        "INSERT INTO process_operations VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload"
      )
      try q.bind(op.id, at: 1)
      try q.bind(op.sessionID.uuidString, at: 2)
      try q.bind(payload, at: 3)
      _ = try q.step()
    }
  }

  public func appendProcessSegment(_ segment: ProcessOutputSegment) throws -> ProcessSessionRecord {
    let c = try requireConnection()
    return try withImmediateOwnedTransaction(connection: c) {
      guard var record = try processSession(segment.sessionID),
        record.outputBytes == segment.offset,
        record.runID == segment.reference.runID, record.callID == segment.reference.toolCallID,
        record.revision < Int64.max
      else { throw ProcessSessionError.revisionConflict }
      let q = try c.prepare(
        "SELECT count(*), coalesce(max(offset + byte_count), 0) FROM process_segments WHERE session_id = ?"
      )
      try q.bind(segment.sessionID.uuidString, at: 1)
      _ = try q.step()
      guard try q.columnInt64(at: 0) < 2_048, try q.columnInt64(at: 1) == segment.offset,
        segment.reference.byteCount > 0,
        segment.offset + segment.reference.byteCount <= 64 * 1_024 * 1_024,
        try c.scalarInt64("SELECT count(*) FROM process_segments") < 8_192,
        try c.scalarInt64("SELECT coalesce(sum(byte_count), 0) FROM process_segments")
          + segment.reference.byteCount <= 512 * 1_024 * 1_024
      else { throw ProcessSessionError.capacity }
      let insert = try c.prepare("INSERT INTO process_segments VALUES (?, ?, ?, ?)")
      try insert.bind(segment.sessionID.uuidString, at: 1)
      try insert.bind(segment.offset, at: 2)
      try insert.bind(segment.reference.byteCount, at: 3)
      try insert.bind(JSONEncoder().encode(segment), at: 4)
      _ = try insert.step()
      record.outputBytes += segment.reference.byteCount
      record.revision += 1
      let update = try c.prepare(
        "UPDATE process_sessions SET revision = ?, payload = ? WHERE id = ?")
      try update.bind(record.revision, at: 1)
      try update.bind(JSONEncoder().encode(record), at: 2)
      try update.bind(record.id.uuidString, at: 3)
      _ = try update.step()
      try validatePhysicalDatabaseSize(connection: c)
      return record
    }
  }

  public func processSegments(_ id: UUID, offset: Int64, limit: Int) throws
    -> [ProcessOutputSegment]
  {
    guard offset >= 0, (1...100).contains(limit) else { throw ProcessSessionError.invalidRequest }
    let q = try requireConnection().prepare(
      "SELECT payload FROM process_segments WHERE session_id = ? AND offset + byte_count > ? ORDER BY offset LIMIT ?"
    )
    try q.bind(id.uuidString, at: 1)
    try q.bind(offset, at: 2)
    try q.bind(Int64(limit), at: 3)
    var result: [ProcessOutputSegment] = []
    while try q.step() == .row {
      result.append(
        try JSONDecoder().decode(
          ProcessOutputSegment.self, from: q.columnBlob(at: 0, maximumBytes: 16_384)))
    }
    return result
  }

  public func interruptProcessSessions() throws {
    var cursor: UUID?
    repeat {
      let records = try processSessions(conversationID: nil, before: cursor, limit: 100)
      for var record in records where !record.terminal {
        record.phase = "interrupted"
        record.cleanupConfirmed = false
        record.explanation =
          "The resident restarted. Cleanup and the output tail are unconfirmed. Do not repeat prior input."
        _ = try saveProcessSession(record)
      }
      cursor = records.count == 100 ? records.last?.id : nil
    } while cursor != nil
  }
}
