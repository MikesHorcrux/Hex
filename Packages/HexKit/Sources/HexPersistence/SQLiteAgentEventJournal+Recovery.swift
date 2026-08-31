import Foundation
import HexCore

extension SQLiteAgentEventJournal {
  func recoverInterruptedRuns() throws -> [InterruptedAgentRun] {
    let connection = try requireConnection()
    return try connection.withImmediateTransaction {
      let interruptedRuns = try interruptedRunIDs(connection: connection)
      var reports: [InterruptedAgentRun] = []
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
        reports.append(
          InterruptedAgentRun(
            runID: runID,
            unresolvedToolCallIDs: validated.unresolvedToolCallIDs
          )
        )
      }

      try Task.checkCancellation()
      for report in reports {
        let failure = AgentFailure(
          code: .invalidState,
          message: "Run interrupted before reaching a terminal state.",
          isRetryable: false
        )
        _ = try appendInTransaction(
          .runFailed(failure),
          to: report.runID,
          connection: connection
        )
      }
      return reports
    }
  }

  private func interruptedRunIDs(
    connection: SQLiteConnection
  ) throws -> (runIDs: [AgentRunID], byteCount: Int) {
    let statement = try connection.prepare(
      """
      SELECT run_id
      FROM runs
      WHERE terminal_sequence IS NULL
      ORDER BY run_id ASC
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
      guard let uuid = UUID(uuidString: value) else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "An interrupted run_id is not a UUID string."
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
    var unresolvedToolCallSequences: [ToolCallID: UInt64] = [:]
    var finishedToolCallIDs: Set<ToolCallID> = []
    var seenAuthorizationRequestIDs: Set<AuthorizationRequestID> = []
    var decidedAuthorizationRequestIDs: Set<AuthorizationRequestID> = []
    var authorizationToolCallIDs: [AuthorizationRequestID: ToolCallID] = [:]
    var deniedToolCallIDs: Set<ToolCallID> = []
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

      switch record.event {
      case .authorizationRequested(let request):
        guard seenAuthorizationRequestIDs.insert(request.id).inserted else {
          throw SQLiteAgentEventJournalError.corruptRecord(
            "An interrupted run contains a duplicate authorization request."
          )
        }
        guard request.runID == runID else {
          throw SQLiteAgentEventJournalError.corruptRecord(
            "An authorization request belongs to a different run."
          )
        }
        if let toolCallID = request.toolCallID {
          authorizationToolCallIDs[request.id] = toolCallID
        }
      case .authorizationDecided(let requestID, let decision):
        guard seenAuthorizationRequestIDs.contains(requestID) else {
          throw SQLiteAgentEventJournalError.corruptRecord(
            "An authorization decision has no preceding request."
          )
        }
        guard decidedAuthorizationRequestIDs.insert(requestID).inserted else {
          throw SQLiteAgentEventJournalError.corruptRecord(
            "An interrupted run contains a duplicate authorization decision."
          )
        }
        if case .deny = decision,
          let toolCallID = authorizationToolCallIDs[requestID]
        {
          deniedToolCallIDs.insert(toolCallID)
        }
      case .toolStarted(let call):
        guard
          unresolvedToolCallSequences[call.id] == nil,
          !finishedToolCallIDs.contains(call.id),
          !deniedToolCallIDs.contains(call.id)
        else {
          throw SQLiteAgentEventJournalError.corruptRecord(
            "An interrupted run contains a duplicate or contradictory tool start."
          )
        }
        unresolvedToolCallSequences[call.id] = record.sequence
      case .toolFinished(let result):
        guard !finishedToolCallIDs.contains(result.toolCallID) else {
          throw SQLiteAgentEventJournalError.corruptRecord(
            "An interrupted run contains a repeated tool finish."
          )
        }
        if unresolvedToolCallSequences.removeValue(forKey: result.toolCallID) == nil {
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
    let unresolvedToolCallIDs =
      unresolvedToolCallSequences
      .sorted { left, right in left.value < right.value }
      .map(\.key)
    return (
      unresolvedToolCallIDs,
      recoveredRecordCount,
      recoveredByteCount
    )
  }
}
