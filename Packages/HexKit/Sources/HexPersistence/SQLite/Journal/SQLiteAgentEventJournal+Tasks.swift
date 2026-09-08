import Foundation
import HexCore

extension SQLiteAgentEventJournal: AgentTaskStorage {
  public func readTask(_ id: UUID) throws -> AgentTaskRecord? {
    try taskRecord(id, connection: requireConnection())
  }

  public func listTasks(after: UUID?, limit: Int, unfinishedOnly: Bool) throws -> [AgentTaskRecord]
  {
    guard (1...100).contains(limit) else { throw AgentTaskStorageError.invalidRecord }
    let connection = try requireConnection()
    let statement = try connection.prepare(
      """
      SELECT payload FROM agent_tasks
      WHERE (? = '' OR rowid < (SELECT rowid FROM agent_tasks WHERE id = ?))
      AND (? = 0 OR phase NOT IN ('completed', 'cancelled')) ORDER BY rowid DESC LIMIT ?
      """)
    try statement.bind(after?.uuidString ?? "", at: 1)
    try statement.bind(after?.uuidString ?? "", at: 2)
    try statement.bind(unfinishedOnly ? Int64(1) : Int64(0), at: 3)
    try statement.bind(Int64(limit), at: 4)
    var result: [AgentTaskRecord] = []
    while try statement.step() == .row {
      result.append(
        try JSONDecoder().decode(
          AgentTaskRecord.self,
          from: statement.columnBlob(at: 0, maximumBytes: 6 * 1_024 * 1_024)
        ).summary)
    }
    return result
  }

  public func taskAttempts(_ id: UUID, before: Int?, limit: Int) throws -> [AgentTaskAttempt] {
    guard (1...20).contains(limit), before == nil || (before ?? 0) > 0 else {
      throw AgentTaskStorageError.invalidRecord
    }
    let connection = try requireConnection()
    let statement = try connection.prepare(
      """
      SELECT run_id, attempt FROM agent_task_attempts
      WHERE task_id = ? AND attempt < ? ORDER BY attempt DESC LIMIT ?
      """)
    try statement.bind(id.uuidString, at: 1)
    try statement.bind(Int64(before ?? Int.max), at: 2)
    try statement.bind(Int64(limit), at: 3)
    var result: [AgentTaskAttempt] = []
    while try statement.step() == .row {
      guard let runID = UUID(uuidString: try statement.columnText(at: 0, maximumBytes: 36)) else {
        throw AgentTaskStorageError.invalidRecord
      }
      result.append(
        .init(runID: AgentRunID(rawValue: runID), number: Int(try statement.columnInt64(at: 1))))
    }
    return result
  }

  public func saveTask(_ input: AgentTaskRecord) throws -> AgentTaskRecord {
    let connection = try requireConnection()
    return try withImmediateOwnedTransaction(connection: connection) {
      try SQLiteJournalMigrator.validateSchemaDefinition(
        connection: connection, maximumTextBytes: configuration.maximumTextBytes)
      try validateIntegrityDataVersion(connection: connection)
      let old = try taskRecord(input.id, connection: connection)
      guard input.revision >= 0, input.revision < Int64.max,
        input.revision == (old?.revision ?? 0)
      else {
        throw AgentTaskStorageError.revisionConflict
      }
      guard input.title.utf8.count <= 1_024, input.explanation.utf8.count <= 16_384,
        input.instructions.count <= 64,
        input.instructions.allSatisfy({ $0.text.utf8.count <= 16_384 }),
        old == nil
          || (old?.admissionHash == input.admissionHash && old?.createdAt == input.createdAt)
      else { throw AgentTaskStorageError.invalidRecord }
      var record = input
      record.revision += 1
      record.updatedAt = Date()
      let payload = try JSONEncoder().encode(record)
      guard payload.count <= 6 * 1_024 * 1_024 else { throw AgentTaskStorageError.invalidRecord }
      let statement = try connection.prepare(
        """
        INSERT INTO agent_tasks (id, phase, revision, payload) VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET phase = excluded.phase,
          revision = excluded.revision, payload = excluded.payload
        """)
      try statement.bind(record.id.uuidString, at: 1)
      try statement.bind(record.phase.rawValue, at: 2)
      try statement.bind(record.revision, at: 3)
      try statement.bind(payload, at: 4)
      _ = try statement.step()
      if let runID = record.runID, runID != old?.runID {
        let attempt = try connection.prepare(
          """
          INSERT INTO agent_task_attempts (task_id, run_id, attempt) VALUES (?, ?, ?)
          """)
        try attempt.bind(record.id.uuidString, at: 1)
        try attempt.bind(runID.rawValue.uuidString, at: 2)
        try attempt.bind(Int64(record.attemptCount), at: 3)
        _ = try attempt.step()
      }
      try validatePhysicalDatabaseSize(connection: connection)
      return record
    }
  }

  private func taskRecord(_ id: UUID, connection: SQLiteConnection) throws -> AgentTaskRecord? {
    let statement = try connection.prepare(
      "SELECT payload, phase, revision FROM agent_tasks WHERE id = ?")
    try statement.bind(id.uuidString, at: 1)
    guard try statement.step() == .row else { return nil }
    let record = try JSONDecoder().decode(
      AgentTaskRecord.self,
      from: statement.columnBlob(at: 0, maximumBytes: 6 * 1_024 * 1_024))
    guard record.id == id,
      record.phase.rawValue == (try statement.columnText(at: 1, maximumBytes: 32)),
      record.revision == (try statement.columnInt64(at: 2))
    else {
      throw AgentTaskStorageError.invalidRecord
    }
    return record
  }
}
