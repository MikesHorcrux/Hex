import Foundation
import HexCore

extension SQLiteAgentEventJournal {
  @discardableResult
  func validateWholeJournalIntegrity(
    connection: SQLiteConnection,
    checksCancellation: Bool = true
  ) throws -> SQLiteJournalIntegrityUsage {
    try validatePhysicalDatabaseIntegrity(
      connection: connection,
      checksCancellation: checksCancellation
    )
    try validateBoundedForeignKeyData(
      connection: connection,
      checksCancellation: checksCancellation
    )
    let runStatement = try connection.prepare(
      """
      SELECT run_id, next_sequence, terminal_sequence
      FROM runs
      LIMIT ?
      """
    )
    try runStatement.bind(Int64(configuration.auditRunLimit + 1), at: 1)
    var runCount = 0
    var recordCount = 0
    var byteCount = 0
    while true {
      if checksCancellation {
        try Task.checkCancellation()
      }
      let stepResult = try runStatement.step()
      if checksCancellation {
        try Task.checkCancellation()
      }
      guard stepResult == .row else {
        break
      }
      guard runCount < configuration.auditRunLimit else {
        throw SQLiteAgentEventJournalError.integrityRunLimitExceeded(
          maximum: configuration.auditRunLimit
        )
      }
      let runIDText = try runStatement.columnText(
        at: 0,
        maximumBytes: configuration.maximumTextBytes
      )
      guard let runUUID = UUID(uuidString: runIDText), runIDText == runUUID.uuidString else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "runs.run_id is not stored as canonical UUID text."
        )
      }
      try addIntegrityBytes(runIDText.utf8.count, to: &byteCount)
      let terminalSequence = try runStatement.columnOptionalInt64(at: 2)
      try validateRunEvents(
        for: AgentRunID(rawValue: runUUID),
        nextSequence: try runStatement.columnInt64(at: 1),
        terminalSequence: terminalSequence,
        connection: connection,
        maximumRecordCount: configuration.auditRecordLimit,
        maximumBytes: configuration.auditByteLimit,
        checksCancellation: checksCancellation,
        recordCount: &recordCount,
        byteCount: &byteCount
      )
      if terminalSequence == nil {
        try reserveRecoveryTerminalIntegrityCapacity(
          runIDTextByteCount: runIDText.utf8.count,
          recordCount: &recordCount,
          byteCount: &byteCount
        )
      }
      runCount += 1
    }

    try validateAllCheckpoints(
      connection: connection,
      checksCancellation: checksCancellation,
      recordCount: &recordCount,
      byteCount: &byteCount
    )
    return SQLiteJournalIntegrityUsage(
      runCount: runCount,
      recordCount: recordCount,
      byteCount: byteCount
    )
  }

  private func validateRunEvents(
    for runID: AgentRunID,
    nextSequence: Int64,
    terminalSequence: Int64?,
    connection: SQLiteConnection,
    maximumRecordCount: Int,
    maximumBytes: Int,
    checksCancellation: Bool = true,
    recordCount: inout Int,
    byteCount: inout Int
  ) throws {
    let statement = try connection.prepare(
      """
      SELECT event_id, run_id, sequence, timestamp_us, record_schema_version, kind, tool_call_id,
             payload
      FROM event_records
      WHERE run_id = ?
      ORDER BY sequence ASC
      LIMIT ?
      """
    )
    try statement.bind(runID.description, at: 1)
    let remainingRecordCount = maximumRecordCount - recordCount
    try statement.bind(Int64(remainingRecordCount + 1), at: 2)
    var expectedSequence: Int64 = 1
    var sawRecord = false
    var runStartedCount = 0
    var terminalCount = 0
    var lastEventTerminatesRun = false
    var lastEventCompletedRun = false
    var lifecycleValidator = SQLiteRunLifecycleValidator(runID: runID)

    while true {
      if checksCancellation {
        try Task.checkCancellation()
      }
      let stepResult = try statement.step()
      if checksCancellation {
        try Task.checkCancellation()
      }
      guard stepResult == .row else {
        break
      }
      guard recordCount < maximumRecordCount else {
        throw SQLiteAgentEventJournalError.integrityRecordLimitExceeded(
          maximum: maximumRecordCount
        )
      }
      guard expectedSequence > 0 else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "A run contains records after exhausting its sequence space."
        )
      }
      let decoded = try decodeRecord(from: statement, expectedRunID: runID)
      try addIntegrityBytes(decoded.byteCount, maximum: maximumBytes, to: &byteCount)
      let record = decoded.record
      guard record.sequence == UInt64(expectedSequence) else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "A run contains a durable sequence gap."
        )
      }
      if record.event.startsRun {
        runStartedCount += 1
      }
      if !sawRecord, !record.event.startsRun {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "A run does not begin with runStarted."
        )
      }
      if record.event.terminatesRun {
        terminalCount += 1
      }
      lastEventTerminatesRun = record.event.terminatesRun
      if case .runCompleted = record.event {
        lastEventCompletedRun = true
      } else {
        lastEventCompletedRun = false
      }
      try lifecycleValidator.consume(record.event, sequence: record.sequence)
      sawRecord = true
      recordCount += 1
      expectedSequence = expectedSequence == Int64.max ? -1 : expectedSequence + 1
    }

    guard sawRecord, runStartedCount == 1 else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "A run must contain exactly one leading runStarted record."
      )
    }
    guard nextSequence == expectedSequence else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "A run's next_sequence contradicts its durable records."
      )
    }
    let maximumSequence = expectedSequence == -1 ? Int64.max : expectedSequence - 1
    if let terminalSequence {
      guard
        terminalSequence == maximumSequence,
        terminalCount == 1,
        lastEventTerminatesRun
      else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "A run's terminal metadata contradicts its durable records."
        )
      }
      if lastEventCompletedRun {
        try lifecycleValidator.validateSuccessfulCompletion()
      }
    } else {
      guard terminalCount == 0, !lastEventTerminatesRun, expectedSequence > 0 else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "A nonterminal run contains terminal or exhausted sequence state."
        )
      }
    }
  }

  private func validateAllCheckpoints(
    connection: SQLiteConnection,
    checksCancellation: Bool,
    recordCount: inout Int,
    byteCount: inout Int
  ) throws {
    let statement = try connection.prepare(
      """
      SELECT c.run_id, c.through_sequence, c.created_at_us, c.checkpoint_schema_version,
             c.snapshot, e.sequence
      FROM journal_checkpoints AS c
      LEFT JOIN event_records AS e
        ON e.run_id = c.run_id AND e.sequence = c.through_sequence
      LIMIT ?
      """
    )
    let remainingRecordCount = configuration.auditRecordLimit - recordCount
    try statement.bind(Int64(remainingRecordCount + 1), at: 1)
    while true {
      if checksCancellation {
        try Task.checkCancellation()
      }
      let stepResult = try statement.step()
      if checksCancellation {
        try Task.checkCancellation()
      }
      guard stepResult == .row else {
        break
      }
      guard recordCount < configuration.auditRecordLimit else {
        throw SQLiteAgentEventJournalError.integrityRecordLimitExceeded(
          maximum: configuration.auditRecordLimit
        )
      }
      let runIDText = try statement.columnText(
        at: 0,
        maximumBytes: configuration.maximumTextBytes
      )
      guard let runUUID = UUID(uuidString: runIDText), runIDText == runUUID.uuidString else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "A checkpoint run_id is not stored as canonical UUID text."
        )
      }
      let decoded = try decodeCheckpointWithByteCount(
        from: statement,
        expectedRunID: AgentRunID(rawValue: runUUID)
      )
      try addIntegrityBytes(
        decoded.byteCount,
        maximum: configuration.auditByteLimit,
        to: &byteCount
      )
      guard
        let referencedSequence = try statement.columnOptionalInt64(at: 5),
        referencedSequence > 0,
        UInt64(referencedSequence) == decoded.checkpoint.throughSequence
      else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "A checkpoint references a missing durable event."
        )
      }
      recordCount += 1
    }
  }

  private func addIntegrityBytes(
    _ additionalBytes: Int,
    maximum: Int = -1,
    to byteCount: inout Int
  ) throws {
    let effectiveMaximum = maximum < 0 ? configuration.auditByteLimit : maximum
    let (nextByteCount, overflowed) = byteCount.addingReportingOverflow(additionalBytes)
    guard !overflowed, nextByteCount <= effectiveMaximum else {
      throw SQLiteAgentEventJournalError.integrityByteLimitExceeded(
        actual: overflowed ? Int.max : nextByteCount,
        maximum: effectiveMaximum
      )
    }
    byteCount = nextByteCount
  }

  private func reserveRecoveryTerminalIntegrityCapacity(
    runIDTextByteCount: Int,
    recordCount: inout Int,
    byteCount: inout Int
  ) throws {
    guard recordCount < configuration.auditRecordLimit else {
      throw SQLiteAgentEventJournalError.integrityRecordLimitExceeded(
        maximum: configuration.auditRecordLimit
      )
    }
    let terminalByteCount = try SQLiteInterruptedRunTerminal.encodedRecordByteCount(
      runIDTextByteCount: runIDTextByteCount,
      configuration: configuration
    )
    try addIntegrityBytes(terminalByteCount, to: &byteCount)
    recordCount += 1
  }
}
