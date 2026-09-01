import Foundation

enum SQLiteJournalMigrationValidator {
  static func validateVersionTwoData(
    connection: SQLiteConnection,
    configuration: SQLiteAgentEventJournalConfiguration
  ) throws {
    var byteCount = 0
    let runs = try validateRuns(
      connection: connection,
      configuration: configuration,
      byteCount: &byteCount
    )
    var recordCount = 0
    try validateEvents(
      runIDs: runs.runIDs,
      connection: connection,
      configuration: configuration,
      recordCount: &recordCount,
      byteCount: &byteCount
    )
    try validateCheckpoints(
      runIDs: runs.runIDs,
      connection: connection,
      configuration: configuration,
      recordCount: &recordCount,
      byteCount: &byteCount
    )
    try reserveRecoveryTerminalCapacity(
      nonterminalRunCount: runs.nonterminalRunCount,
      configuration: configuration,
      recordCount: &recordCount,
      byteCount: &byteCount
    )
  }

  private static func validateRuns(
    connection: SQLiteConnection,
    configuration: SQLiteAgentEventJournalConfiguration,
    byteCount: inout Int
  ) throws -> (runIDs: Set<String>, nonterminalRunCount: Int) {
    let statement = try connection.prepare(
      "SELECT run_id, terminal_sequence FROM runs LIMIT ?"
    )
    try statement.bind(Int64(configuration.maximumRecoveryRunCount + 1), at: 1)
    var runIDs: Set<String> = []
    runIDs.reserveCapacity(min(configuration.maximumRecoveryRunCount, 256))
    var nonterminalRunCount = 0
    while true {
      try Task.checkCancellation()
      guard try statement.step() == .row else {
        break
      }
      guard runIDs.count < configuration.maximumRecoveryRunCount else {
        throw SQLiteAgentEventJournalError.integrityRunLimitExceeded(
          maximum: configuration.maximumRecoveryRunCount
        )
      }
      let value = try statement.columnText(
        at: 0,
        maximumBytes: configuration.maximumTextBytes
      )
      let canonicalValue = try canonicalUUID(value, label: "runs.run_id")
      guard runIDs.insert(canonicalValue).inserted else {
        throw SQLiteAgentEventJournalError.corruptSchema(
          "runs.run_id contains a case-insensitive UUID collision."
        )
      }
      if try statement.columnOptionalInt64(at: 1) == nil {
        nonterminalRunCount += 1
      }
      try addBytes(value.utf8.count, configuration: configuration, byteCount: &byteCount)
    }
    return (runIDs, nonterminalRunCount)
  }

  private static func validateEvents(
    runIDs: Set<String>,
    connection: SQLiteConnection,
    configuration: SQLiteAgentEventJournalConfiguration,
    recordCount: inout Int,
    byteCount: inout Int
  ) throws {
    let statement = try connection.prepare(
      "SELECT event_id, run_id, kind, tool_call_id, payload FROM event_records LIMIT ?"
    )
    try statement.bind(Int64(configuration.maximumRecoveryRecordCount + 1), at: 1)
    var eventIDs: Set<String> = []
    eventIDs.reserveCapacity(min(configuration.maximumRecoveryRecordCount, 256))
    while true {
      try Task.checkCancellation()
      guard try statement.step() == .row else {
        break
      }
      try requireRecordCapacity(recordCount, configuration: configuration)
      let eventID = try statement.columnText(
        at: 0,
        maximumBytes: configuration.maximumTextBytes
      )
      let canonicalEventID = try canonicalUUID(eventID, label: "event_records.event_id")
      guard eventIDs.insert(canonicalEventID).inserted else {
        throw SQLiteAgentEventJournalError.corruptSchema(
          "event_records.event_id contains a case-insensitive UUID collision."
        )
      }
      let runID = try statement.columnText(
        at: 1,
        maximumBytes: configuration.maximumTextBytes
      )
      let canonicalRunID = try canonicalUUID(runID, label: "event_records.run_id")
      guard runIDs.contains(canonicalRunID) else {
        throw SQLiteAgentEventJournalError.corruptSchema(
          "event_records contains a foreign-key violation."
        )
      }
      let kind = try statement.columnText(
        at: 2,
        maximumBytes: configuration.maximumTextBytes
      )
      let toolCallID = try statement.columnOptionalText(
        at: 3,
        maximumBytes: configuration.maximumTextBytes
      )
      let payload = try statement.columnBlob(
        at: 4,
        maximumBytes: configuration.maximumPayloadBytes
      )
      for size in [
        eventID.utf8.count,
        runID.utf8.count,
        kind.utf8.count,
        toolCallID?.utf8.count ?? 0,
        payload.count,
      ] {
        try addBytes(size, configuration: configuration, byteCount: &byteCount)
      }
      recordCount += 1
    }
  }

  private static func validateCheckpoints(
    runIDs: Set<String>,
    connection: SQLiteConnection,
    configuration: SQLiteAgentEventJournalConfiguration,
    recordCount: inout Int,
    byteCount: inout Int
  ) throws {
    let remainingCapacity = configuration.maximumRecoveryRecordCount - recordCount
    let statement = try connection.prepare(
      "SELECT run_id, snapshot FROM journal_checkpoints LIMIT ?"
    )
    try statement.bind(Int64(remainingCapacity + 1), at: 1)
    while true {
      try Task.checkCancellation()
      guard try statement.step() == .row else {
        break
      }
      try requireRecordCapacity(recordCount, configuration: configuration)
      let runID = try statement.columnText(
        at: 0,
        maximumBytes: configuration.maximumTextBytes
      )
      let canonicalRunID = try canonicalUUID(runID, label: "journal_checkpoints.run_id")
      guard runIDs.contains(canonicalRunID) else {
        throw SQLiteAgentEventJournalError.corruptSchema(
          "journal_checkpoints contains a foreign-key violation."
        )
      }
      let snapshot = try statement.columnBlob(
        at: 1,
        maximumBytes: configuration.maximumPayloadBytes
      )
      try addBytes(runID.utf8.count, configuration: configuration, byteCount: &byteCount)
      try addBytes(snapshot.count, configuration: configuration, byteCount: &byteCount)
      recordCount += 1
    }
  }

  private static func canonicalUUID(_ value: String, label: String) throws -> String {
    guard let uuid = UUID(uuidString: value) else {
      throw SQLiteAgentEventJournalError.corruptSchema(
        "\(label) contains text that is not a UUID."
      )
    }
    return uuid.uuidString
  }

  private static func requireRecordCapacity(
    _ recordCount: Int,
    configuration: SQLiteAgentEventJournalConfiguration
  ) throws {
    guard recordCount < configuration.maximumRecoveryRecordCount else {
      throw SQLiteAgentEventJournalError.integrityRecordLimitExceeded(
        maximum: configuration.maximumRecoveryRecordCount
      )
    }
  }

  private static func addBytes(
    _ additionalBytes: Int,
    configuration: SQLiteAgentEventJournalConfiguration,
    byteCount: inout Int
  ) throws {
    let (nextByteCount, overflowed) = byteCount.addingReportingOverflow(additionalBytes)
    guard !overflowed, nextByteCount <= configuration.maximumRecoveryBytes else {
      throw SQLiteAgentEventJournalError.integrityByteLimitExceeded(
        actual: overflowed ? Int.max : nextByteCount,
        maximum: configuration.maximumRecoveryBytes
      )
    }
    byteCount = nextByteCount
  }

  private static func reserveRecoveryTerminalCapacity(
    nonterminalRunCount: Int,
    configuration: SQLiteAgentEventJournalConfiguration,
    recordCount: inout Int,
    byteCount: inout Int
  ) throws {
    let (nextRecordCount, recordCountOverflowed) = recordCount.addingReportingOverflow(
      nonterminalRunCount
    )
    guard
      !recordCountOverflowed,
      nextRecordCount <= configuration.maximumRecoveryRecordCount
    else {
      throw SQLiteAgentEventJournalError.integrityRecordLimitExceeded(
        maximum: configuration.maximumRecoveryRecordCount
      )
    }
    guard nonterminalRunCount > 0 else {
      return
    }
    let terminalByteCount = try SQLiteInterruptedRunTerminal.encodedRecordByteCount(
      runIDTextByteCount: 36,
      configuration: configuration
    )
    let (reservedBytes, reserveOverflowed) = terminalByteCount.multipliedReportingOverflow(
      by: nonterminalRunCount
    )
    guard !reserveOverflowed else {
      throw SQLiteAgentEventJournalError.integrityByteLimitExceeded(
        actual: Int.max,
        maximum: configuration.maximumRecoveryBytes
      )
    }
    try addBytes(
      reservedBytes,
      configuration: configuration,
      byteCount: &byteCount
    )
    recordCount = nextRecordCount
  }
}
