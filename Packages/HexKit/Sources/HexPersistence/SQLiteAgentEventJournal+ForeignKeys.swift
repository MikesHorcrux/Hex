import Foundation

extension SQLiteAgentEventJournal {
  func validateBoundedForeignKeyData(connection: SQLiteConnection) throws {
    var recordCount = 0
    try validateBoundedRunReferences(
      table: "event_records",
      connection: connection,
      recordCount: &recordCount
    )
    try validateBoundedRunReferences(
      table: "journal_checkpoints",
      connection: connection,
      recordCount: &recordCount
    )
  }

  private func validateBoundedRunReferences(
    table: String,
    connection: SQLiteConnection,
    recordCount: inout Int
  ) throws {
    let remainingCapacity = configuration.maximumRecoveryRecordCount - recordCount
    let statement = try connection.prepare("SELECT run_id FROM \(table) LIMIT ?")
    try statement.bind(Int64(remainingCapacity + 1), at: 1)
    while true {
      try Task.checkCancellation()
      let stepResult = try statement.step()
      try Task.checkCancellation()
      guard stepResult == .row else {
        break
      }
      guard recordCount < configuration.maximumRecoveryRecordCount else {
        throw SQLiteAgentEventJournalError.integrityRecordLimitExceeded(
          maximum: configuration.maximumRecoveryRecordCount
        )
      }
      let runID = try statement.columnText(
        at: 0,
        maximumBytes: configuration.maximumTextBytes
      )
      guard let uuid = UUID(uuidString: runID), runID == uuid.uuidString else {
        throw SQLiteAgentEventJournalError.corruptSchema(
          "\(table).run_id is not stored as canonical UUID text."
        )
      }
      let referencedRun = try connection.prepare("SELECT 1 FROM runs WHERE run_id = ? LIMIT 1")
      try referencedRun.bind(runID, at: 1)
      guard try referencedRun.step() == .row else {
        throw SQLiteAgentEventJournalError.corruptSchema(
          "\(table) contains a foreign-key violation."
        )
      }
      recordCount += 1
    }
  }
}
