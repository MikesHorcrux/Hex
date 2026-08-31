import Foundation
import HexCore

extension SQLiteAgentEventJournal {
  func validateWholeJournalIntegrity(connection: SQLiteConnection) throws {
    try SQLiteJournalMigrator.validateForeignKeyData(connection: connection)
    let runStatement = try connection.prepare(
      """
      SELECT run_id, next_sequence, terminal_sequence
      FROM runs
      ORDER BY run_id COLLATE NOCASE
      LIMIT ?
      """
    )
    try runStatement.bind(Int64(configuration.maximumRecoveryRunCount + 1), at: 1)
    var runCount = 0
    var recordCount = 0
    var byteCount = 0
    while true {
      try Task.checkCancellation()
      let stepResult = try runStatement.step()
      try Task.checkCancellation()
      guard stepResult == .row else {
        break
      }
      guard runCount < configuration.maximumRecoveryRunCount else {
        throw SQLiteAgentEventJournalError.integrityRunLimitExceeded(
          maximum: configuration.maximumRecoveryRunCount
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
      try validateRunEvents(
        for: AgentRunID(rawValue: runUUID),
        nextSequence: try runStatement.columnInt64(at: 1),
        terminalSequence: try runStatement.columnOptionalInt64(at: 2),
        connection: connection,
        recordCount: &recordCount,
        byteCount: &byteCount
      )
      runCount += 1
    }

    try validateAllCheckpoints(
      connection: connection,
      recordCount: &recordCount,
      byteCount: &byteCount
    )
  }

  private func validateRunEvents(
    for runID: AgentRunID,
    nextSequence: Int64,
    terminalSequence: Int64?,
    connection: SQLiteConnection,
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
    let remainingRecordCount = configuration.maximumRecoveryRecordCount - recordCount
    try statement.bind(Int64(remainingRecordCount + 1), at: 2)
    var expectedSequence: Int64 = 1
    var sawRecord = false
    var runStartedCount = 0
    var terminalCount = 0
    var lastEventTerminatesRun = false
    var unresolvedToolCallIDs: Set<ToolCallID> = []
    var finishedToolCallIDs: Set<ToolCallID> = []
    var authorizationRequestIDs: Set<AuthorizationRequestID> = []
    var decidedAuthorizationRequestIDs: Set<AuthorizationRequestID> = []
    var authorizationToolCallIDs: [AuthorizationRequestID: ToolCallID] = [:]
    var deniedToolCallIDs: Set<ToolCallID> = []

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
      guard expectedSequence > 0 else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "A run contains records after exhausting its sequence space."
        )
      }
      let decoded = try decodeRecord(from: statement, expectedRunID: runID)
      try addIntegrityBytes(decoded.byteCount, to: &byteCount)
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
      try validateEventLifecycle(
        record.event,
        runID: runID,
        unresolvedToolCallIDs: &unresolvedToolCallIDs,
        finishedToolCallIDs: &finishedToolCallIDs,
        authorizationRequestIDs: &authorizationRequestIDs,
        decidedAuthorizationRequestIDs: &decidedAuthorizationRequestIDs,
        authorizationToolCallIDs: &authorizationToolCallIDs,
        deniedToolCallIDs: &deniedToolCallIDs
      )
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
    } else {
      guard terminalCount == 0, !lastEventTerminatesRun, expectedSequence > 0 else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "A nonterminal run contains terminal or exhausted sequence state."
        )
      }
    }
  }

  private func validateEventLifecycle(
    _ event: AgentEvent,
    runID: AgentRunID,
    unresolvedToolCallIDs: inout Set<ToolCallID>,
    finishedToolCallIDs: inout Set<ToolCallID>,
    authorizationRequestIDs: inout Set<AuthorizationRequestID>,
    decidedAuthorizationRequestIDs: inout Set<AuthorizationRequestID>,
    authorizationToolCallIDs: inout [AuthorizationRequestID: ToolCallID],
    deniedToolCallIDs: inout Set<ToolCallID>
  ) throws {
    switch event {
    case .authorizationRequested(let request):
      guard request.runID == runID else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "An authorization request belongs to a different run."
        )
      }
      guard authorizationRequestIDs.insert(request.id).inserted else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "A run contains a duplicate authorization request."
        )
      }
      if let toolCallID = request.toolCallID {
        authorizationToolCallIDs[request.id] = toolCallID
      }
    case .authorizationDecided(let requestID, let decision):
      guard authorizationRequestIDs.contains(requestID) else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "An authorization decision has no preceding request."
        )
      }
      guard decidedAuthorizationRequestIDs.insert(requestID).inserted else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "A run contains a repeated authorization decision."
        )
      }
      if case .deny = decision, let toolCallID = authorizationToolCallIDs[requestID] {
        deniedToolCallIDs.insert(toolCallID)
      }
    case .toolStarted(let call):
      guard
        unresolvedToolCallIDs.insert(call.id).inserted,
        !finishedToolCallIDs.contains(call.id),
        !deniedToolCallIDs.contains(call.id)
      else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "A run contains a duplicate or contradictory tool start."
        )
      }
    case .toolFinished(let result):
      guard !finishedToolCallIDs.contains(result.toolCallID) else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "A run contains a repeated tool finish."
        )
      }
      if unresolvedToolCallIDs.remove(result.toolCallID) == nil {
        guard result.status == .failure, deniedToolCallIDs.contains(result.toolCallID) else {
          throw SQLiteAgentEventJournalError.corruptRecord(
            "A tool finish has no unresolved start or prior authorization denial."
          )
        }
      }
      finishedToolCallIDs.insert(result.toolCallID)
    default:
      break
    }
  }

  private func validateAllCheckpoints(
    connection: SQLiteConnection,
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
      ORDER BY c.run_id COLLATE NOCASE, c.through_sequence ASC
      LIMIT ?
      """
    )
    let remainingRecordCount = configuration.maximumRecoveryRecordCount - recordCount
    try statement.bind(Int64(remainingRecordCount + 1), at: 1)
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
      try addIntegrityBytes(decoded.byteCount, to: &byteCount)
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

  private func addIntegrityBytes(_ additionalBytes: Int, to byteCount: inout Int) throws {
    let (nextByteCount, overflowed) = byteCount.addingReportingOverflow(additionalBytes)
    guard !overflowed, nextByteCount <= configuration.maximumRecoveryBytes else {
      throw SQLiteAgentEventJournalError.integrityByteLimitExceeded(
        actual: overflowed ? Int.max : nextByteCount,
        maximum: configuration.maximumRecoveryBytes
      )
    }
    byteCount = nextByteCount
  }
}
