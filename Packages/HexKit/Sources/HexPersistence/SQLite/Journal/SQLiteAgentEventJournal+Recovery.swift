import Foundation
import HexCore

extension SQLiteAgentEventJournal {
  func recoverInterruptedRuns() throws -> [InterruptedAgentRun] {
    let connection = try requireConnection()
    let recovered = try withImmediateOwnedTransaction(connection: connection) {
      try Task.checkCancellation()
      try SQLiteJournalMigrator.validateSchemaDefinition(
        connection: connection,
        maximumTextBytes: configuration.maximumTextBytes
      )
      let interruptedRuns = try interruptedRunIDs(connection: connection)
      var reports: [InterruptedAgentRun] = []
      var pendingRecoveryEvents: [AgentRunID: [AgentEvent]] = [:]
      reports.reserveCapacity(interruptedRuns.runIDs.count)
      var recoveredRecordCount = 0
      var recoveredByteCount = interruptedRuns.byteCount

      for runID in interruptedRuns.runIDs {
        try Task.checkCancellation()
        let validated = try validateInterruptedRun(
          for: runID,
          connection: connection,
          startingRecordCount: recoveredRecordCount,
          startingByteCount: recoveredByteCount
        )
        recoveredRecordCount = validated.recordCount
        recoveredByteCount = validated.byteCount
        pendingRecoveryEvents[runID] = validated.nonExecutionEvents
        try reserveRecoveryTerminalCapacity(
          for: runID,
          recordCount: &recoveredRecordCount,
          byteCount: &recoveredByteCount
        )
        reports.append(
          InterruptedAgentRun(
            runID: runID,
            unresolvedToolCallIDs: validated.unresolvedToolCallIDs
          )
        )
      }

      var recoveryUsage = try validateWholeJournalIntegrity(connection: connection)
      try Task.checkCancellation()
      for report in reports {
        try Task.checkCancellation()
        let closures = pendingRecoveryEvents[report.runID] ?? []
        if let updatedUsage = try reservingInterruptedToolClosures(
          closures, for: report.runID, usage: recoveryUsage)
        {
          recoveryUsage = updatedUsage
          for event in closures {
            try Task.checkCancellation()
            _ = try appendInTransaction(event, to: report.runID, connection: connection)
          }
        }
        _ = try appendInTransaction(
          SQLiteInterruptedRunTerminal.event,
          to: report.runID,
          connection: connection
        )
      }
      let integrityUsage = try validateWholeJournalIntegrity(connection: connection)
      try Task.checkCancellation()
      return (
        reports: reports,
        integrityUsage: integrityUsage,
        dataVersion: try currentDataVersion(connection: connection)
      )
    }
    integrityUsage = recovered.integrityUsage
    integrityDataVersion = recovered.dataVersion
    activeRunStates.removeAll()
    return recovered.reports
  }

  private func interruptedRunIDs(
    connection: SQLiteConnection
  ) throws -> (runIDs: [AgentRunID], byteCount: Int) {
    let statement = try connection.prepare(
      """
      SELECT run_id
      FROM runs
      WHERE terminal_sequence IS NULL
      LIMIT ?
      """
    )
    try statement.bind(Int64(configuration.maximumRecoveryRunCount + 1), at: 1)
    var runIDs: [AgentRunID] = []
    runIDs.reserveCapacity(min(configuration.maximumRecoveryRunCount, 256))
    var byteCount = 0
    while true {
      try Task.checkCancellation()
      let stepResult = try statement.step()
      try Task.checkCancellation()
      guard stepResult == .row else {
        break
      }
      guard runIDs.count < configuration.maximumRecoveryRunCount else {
        throw SQLiteAgentEventJournalError.recoveryRunLimitExceeded(
          maximum: configuration.maximumRecoveryRunCount
        )
      }
      let value = try statement.columnText(
        at: 0,
        maximumBytes: configuration.maximumTextBytes
      )
      let (nextByteCount, overflowed) = byteCount.addingReportingOverflow(value.utf8.count)
      guard !overflowed, nextByteCount <= configuration.maximumRecoveryBytes else {
        throw SQLiteAgentEventJournalError.recoveryByteLimitExceeded(
          actual: overflowed ? Int.max : nextByteCount,
          maximum: configuration.maximumRecoveryBytes
        )
      }
      guard let uuid = UUID(uuidString: value), value == uuid.uuidString else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "An interrupted run_id is not stored as canonical UUID text."
        )
      }
      runIDs.append(AgentRunID(rawValue: uuid))
      byteCount = nextByteCount
    }
    return (runIDs, byteCount)
  }

  private func validateInterruptedRun(
    for runID: AgentRunID,
    connection: SQLiteConnection,
    startingRecordCount: Int,
    startingByteCount: Int
  ) throws -> (
    unresolvedToolCallIDs: [ToolCallID],
    nonExecutionEvents: [AgentEvent],
    recordCount: Int,
    byteCount: Int
  ) {
    let runStatement = try connection.prepare(
      "SELECT next_sequence, terminal_sequence FROM runs WHERE run_id = ?"
    )
    try runStatement.bind(runID.description, at: 1)
    guard try runStatement.step() == .row else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "An interrupted run disappeared during recovery."
      )
    }
    let storedNextSequence = try runStatement.columnInt64(at: 0)
    guard try runStatement.columnOptionalInt64(at: 1) == nil else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "An interrupted run unexpectedly has a terminal sequence."
      )
    }

    let recordStatement = try connection.prepare(
      """
      SELECT event_id, run_id, sequence, timestamp_us, record_schema_version, kind, tool_call_id,
             payload
      FROM event_records
      WHERE run_id = ?
      ORDER BY sequence ASC
      LIMIT ?
      """
    )
    try recordStatement.bind(runID.description, at: 1)
    let remainingRecordCount = configuration.maximumRecoveryRecordCount - startingRecordCount
    try recordStatement.bind(Int64(remainingRecordCount + 1), at: 2)

    var expectedSequence: Int64 = 1
    var sawRecord = false
    var lifecycleValidator = SQLiteRunLifecycleValidator(runID: runID)
    var recoveredRecordCount = startingRecordCount
    var recoveredByteCount = startingByteCount
    while true {
      try Task.checkCancellation()
      let stepResult = try recordStatement.step()
      try Task.checkCancellation()
      guard stepResult == .row else {
        break
      }
      guard recoveredRecordCount < configuration.maximumRecoveryRecordCount else {
        throw SQLiteAgentEventJournalError.recoveryRecordLimitExceeded(
          maximum: configuration.maximumRecoveryRecordCount
        )
      }
      let decoded = try decodeRecord(from: recordStatement, expectedRunID: runID)
      let (nextByteCount, overflowed) = recoveredByteCount.addingReportingOverflow(
        decoded.byteCount
      )
      guard !overflowed, nextByteCount <= configuration.maximumRecoveryBytes else {
        throw SQLiteAgentEventJournalError.recoveryByteLimitExceeded(
          actual: overflowed ? Int.max : nextByteCount,
          maximum: configuration.maximumRecoveryBytes
        )
      }
      let record = decoded.record
      guard record.sequence == UInt64(expectedSequence) else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "An interrupted run has a sequence gap."
        )
      }
      if !sawRecord {
        guard record.event.startsRun else {
          throw SQLiteAgentEventJournalError.corruptRecord(
            "An interrupted run does not begin with runStarted."
          )
        }
      } else if record.event.startsRun {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "An interrupted run contains a duplicate runStarted event."
        )
      }
      guard !record.event.terminatesRun else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "An interrupted run contains an unindexed terminal event."
        )
      }

      try lifecycleValidator.consume(record.event, sequence: record.sequence)

      sawRecord = true
      recoveredRecordCount += 1
      recoveredByteCount = nextByteCount
      expectedSequence = expectedSequence == Int64.max ? -1 : expectedSequence + 1
    }
    guard sawRecord else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "An interrupted run has no durable events."
      )
    }
    guard storedNextSequence == expectedSequence else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "An interrupted run's next_sequence does not match its durable records."
      )
    }
    return (
      lifecycleValidator.unresolvedToolCallIDs,
      lifecycleValidator.interruptedNonExecutionEvents,
      recoveredRecordCount,
      recoveredByteCount
    )
  }

  /// Legacy admission reserved one terminal record, not two receipts per declared tool. Optional
  /// closure must never consume that reservation or make an otherwise recoverable journal fail to
  /// open. If the complete closure group cannot fit, retain the original incomplete history and its
  /// explicit interrupted terminal; do not claim a receipt was saved or drop part of a pair.
  private func reservingInterruptedToolClosures(
    _ events: [AgentEvent], for runID: AgentRunID, usage: SQLiteJournalIntegrityUsage
  ) throws -> SQLiteJournalIntegrityUsage? {
    var byteCount = 0
    for event in events {
      let payload = try AgentEventCodec.encode(event: event)
      guard payload.count <= configuration.maximumPayloadBytes else { return nil }
      let fields = [runID.description, event.journalKind, event.journalToolCallID?.rawValue ?? ""]
      guard fields.allSatisfy({ $0.utf8.count <= configuration.maximumTextBytes }) else {
        return nil
      }
      // Exactly the record fields counted by decodeRecord, including the optional tool-call index.
      for size in [36, payload.count] + fields.map({ $0.utf8.count }) {
        let (next, overflow) = byteCount.addingReportingOverflow(size)
        guard !overflow else { return nil }
        byteCount = next
      }
    }
    do {
      return try usage.replacing(
        .zero,
        with: SQLiteJournalIntegrityUsage(
          runCount: 0, recordCount: events.count, byteCount: byteCount),
        configuration: configuration)
    } catch SQLiteAgentEventJournalError.integrityRecordLimitExceeded {
      return nil
    } catch SQLiteAgentEventJournalError.integrityByteLimitExceeded {
      return nil
    }
  }

  private func reserveRecoveryTerminalCapacity(
    for runID: AgentRunID,
    recordCount: inout Int,
    byteCount: inout Int
  ) throws {
    guard recordCount < configuration.maximumRecoveryRecordCount else {
      throw SQLiteAgentEventJournalError.recoveryRecordLimitExceeded(
        maximum: configuration.maximumRecoveryRecordCount
      )
    }
    let terminalByteCount = try SQLiteInterruptedRunTerminal.encodedRecordByteCount(
      runIDTextByteCount: runID.description.utf8.count,
      configuration: configuration
    )
    let (nextByteCount, overflowed) = byteCount.addingReportingOverflow(terminalByteCount)
    guard !overflowed, nextByteCount <= configuration.maximumRecoveryBytes else {
      throw SQLiteAgentEventJournalError.recoveryByteLimitExceeded(
        actual: overflowed ? Int.max : nextByteCount,
        maximum: configuration.maximumRecoveryBytes
      )
    }
    recordCount += 1
    byteCount = nextByteCount
  }
}
