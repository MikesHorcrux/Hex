import Foundation
import HexCore

extension SQLiteAgentEventJournal {
  public func records(
    for runID: AgentRunID,
    after sequence: UInt64?,
    limit: Int
  ) async throws -> [AgentEventRecord] {
    try Task.checkCancellation()
    guard (1...configuration.maximumReadLimit).contains(limit) else {
      throw SQLiteAgentEventJournalError.invalidReadLimit(
        requested: limit,
        maximum: configuration.maximumReadLimit
      )
    }
    let connection = try requireConnection()
    return try connection.withDeferredTransaction {
      try Task.checkCancellation()
      guard let integrity = try runIntegrityState(for: runID, connection: connection) else {
        return []
      }
      let afterSequence: Int64
      if let sequence, sequence > UInt64(Int64.max) {
        afterSequence = Int64.max
      } else {
        afterSequence = Int64(sequence ?? 0)
      }
      let snapshot = try readValidatedSnapshot(
        for: runID,
        after: afterSequence,
        limit: limit,
        connection: connection
      )
      try validateRunIntegrity(integrity, snapshot: snapshot)
      try validatePage(
        snapshot.pageRecords,
        after: afterSequence,
        limit: limit,
        integrity: integrity
      )
      try Task.checkCancellation()
      return snapshot.pageRecords
    }
  }

  private func runIntegrityState(
    for runID: AgentRunID,
    connection: SQLiteConnection
  ) throws -> SQLiteRunIntegrityState? {
    let statement = try connection.prepare(
      """
      SELECT r.next_sequence,
             r.terminal_sequence,
             COUNT(e.sequence),
             MIN(e.sequence),
             MAX(e.sequence),
             COALESCE(SUM(CASE WHEN e.kind = 'run_started' THEN 1 ELSE 0 END), 0),
             COALESCE(SUM(CASE WHEN e.kind IN (
               'run_completed', 'run_cancelled', 'run_failed'
             ) THEN 1 ELSE 0 END), 0)
      FROM runs AS r
      LEFT JOIN event_records AS e ON e.run_id = r.run_id
      WHERE r.run_id = ?
      GROUP BY r.run_id, r.next_sequence, r.terminal_sequence
      """
    )
    try statement.bind(runID.description, at: 1)
    guard try statement.step() == .row else {
      let orphanStatement = try connection.prepare(
        "SELECT COUNT(*) FROM event_records WHERE run_id = ?"
      )
      try orphanStatement.bind(runID.description, at: 1)
      guard
        try orphanStatement.step() == .row,
        try orphanStatement.columnInt64(at: 0) == 0
      else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "Event records exist without their run metadata."
        )
      }
      return nil
    }
    return SQLiteRunIntegrityState(
      nextSequence: try statement.columnInt64(at: 0),
      terminalSequence: try statement.columnOptionalInt64(at: 1),
      recordCount: try statement.columnInt64(at: 2),
      minimumSequence: try statement.columnOptionalInt64(at: 3),
      maximumSequence: try statement.columnOptionalInt64(at: 4),
      runStartedKindCount: try statement.columnInt64(at: 5),
      terminalKindCount: try statement.columnInt64(at: 6)
    )
  }

  private func validateRunIntegrity(
    _ integrity: SQLiteRunIntegrityState,
    snapshot: SQLiteValidatedRunSnapshot
  ) throws {
    guard
      integrity.recordCount > 0,
      integrity.minimumSequence == 1,
      let maximumSequence = integrity.maximumSequence,
      maximumSequence > 0,
      maximumSequence == integrity.recordCount,
      snapshot.recordCount == integrity.recordCount,
      snapshot.minimumSequence == integrity.minimumSequence,
      snapshot.maximumSequence == integrity.maximumSequence
    else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "The run's durable sequences are empty, gapped, or noncontiguous."
      )
    }
    guard
      integrity.runStartedKindCount == 1,
      snapshot.runStartedEventCount == 1,
      snapshot.firstRecordStartsRun
    else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "The run must begin with exactly one runStarted record."
      )
    }

    let expectedNextSequence = maximumSequence == Int64.max ? -1 : maximumSequence + 1
    guard integrity.nextSequence == expectedNextSequence else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "The run's next_sequence contradicts its durable records."
      )
    }

    if let terminalSequence = integrity.terminalSequence {
      guard
        terminalSequence == maximumSequence,
        integrity.terminalKindCount == 1,
        snapshot.terminalEventCount == 1,
        snapshot.lastRecordTerminatesRun
      else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "The run's terminal metadata contradicts its durable terminal record."
        )
      }
    } else {
      guard
        maximumSequence < Int64.max,
        integrity.terminalKindCount == 0,
        snapshot.terminalEventCount == 0,
        !snapshot.lastRecordTerminatesRun
      else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "A nonterminal run contains terminal data or an exhausted sequence."
        )
      }
    }
  }

  private func readValidatedSnapshot(
    for runID: AgentRunID,
    after sequence: Int64,
    limit: Int,
    connection: SQLiteConnection
  ) throws -> SQLiteValidatedRunSnapshot {
    let statement = try connection.prepare(
      """
      SELECT event_id, run_id, sequence, timestamp_us, record_schema_version, kind, tool_call_id,
             payload
      FROM event_records
      WHERE run_id = ?
      ORDER BY sequence ASC
      """
    )
    try statement.bind(runID.description, at: 1)

    var pageRecords: [AgentEventRecord] = []
    pageRecords.reserveCapacity(min(limit, 256))
    var recordCount: Int64 = 0
    var minimumSequence: Int64?
    var maximumSequence: Int64?
    var runStartedEventCount: Int64 = 0
    var terminalEventCount: Int64 = 0
    var firstRecordStartsRun = false
    var lastRecordTerminatesRun = false
    var expectedSequence: Int64 = 1
    var decodedBytes = 0
    while true {
      try Task.checkCancellation()
      let stepResult = try statement.step()
      try Task.checkCancellation()
      guard stepResult == .row else {
        break
      }
      let decoded = try decodeRecord(from: statement, expectedRunID: runID)
      let record = decoded.record
      let (nextDecodedBytes, overflowed) = decodedBytes.addingReportingOverflow(
        decoded.byteCount
      )
      guard !overflowed, nextDecodedBytes <= configuration.maximumReadBytes else {
        throw SQLiteAgentEventJournalError.readByteLimitExceeded(
          actual: overflowed ? Int.max : nextDecodedBytes,
          maximum: configuration.maximumReadBytes
        )
      }
      decodedBytes = nextDecodedBytes
      guard expectedSequence > 0, record.sequence == UInt64(expectedSequence) else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "The run contains a durable sequence gap."
        )
      }
      let (nextRecordCount, countOverflowed) = recordCount.addingReportingOverflow(1)
      guard !countOverflowed else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "The run's durable record count overflowed."
        )
      }
      recordCount = nextRecordCount
      if minimumSequence == nil {
        minimumSequence = expectedSequence
        firstRecordStartsRun = record.event.startsRun
      }
      maximumSequence = expectedSequence
      lastRecordTerminatesRun = record.event.terminatesRun
      if record.event.startsRun {
        runStartedEventCount += 1
      }
      if record.event.terminatesRun {
        terminalEventCount += 1
      }
      if expectedSequence > sequence, pageRecords.count < limit {
        pageRecords.append(record)
      }
      expectedSequence = expectedSequence == Int64.max ? -1 : expectedSequence + 1
    }
    return SQLiteValidatedRunSnapshot(
      pageRecords: pageRecords,
      recordCount: recordCount,
      minimumSequence: minimumSequence,
      maximumSequence: maximumSequence,
      runStartedEventCount: runStartedEventCount,
      terminalEventCount: terminalEventCount,
      firstRecordStartsRun: firstRecordStartsRun,
      lastRecordTerminatesRun: lastRecordTerminatesRun
    )
  }

  private func validatePage(
    _ records: [AgentEventRecord],
    after sequence: Int64,
    limit: Int,
    integrity: SQLiteRunIntegrityState
  ) throws {
    guard let maximumSequence = integrity.maximumSequence else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "The run has no maximum durable sequence."
      )
    }
    let available = maximumSequence > sequence ? maximumSequence - sequence : 0
    let expectedCount = available >= Int64(limit) ? limit : Int(available)
    guard records.count == expectedCount else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "A paginated read omitted one or more expected durable records."
      )
    }
    for (offset, record) in records.enumerated() {
      let expectedSequence = UInt64(sequence + Int64(offset) + 1)
      guard record.sequence == expectedSequence else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "A paginated read returned a sequence gap."
        )
      }
      if record.event.startsRun, record.sequence != 1 {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "A paginated read found a duplicate runStarted event."
        )
      }
      if record.event.terminatesRun,
        record.sequence != integrity.terminalSequence.map(UInt64.init)
      {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "A paginated read found an unindexed terminal event."
        )
      }
    }
  }

  func decodeRecord(
    from statement: SQLiteStatement,
    expectedRunID: AgentRunID
  ) throws -> (record: AgentEventRecord, byteCount: Int) {
    let eventIDString = try statement.columnText(
      at: 0,
      maximumBytes: configuration.maximumTextBytes
    )
    guard let eventUUID = UUID(uuidString: eventIDString) else {
      throw SQLiteAgentEventJournalError.corruptRecord("event_id is not a UUID string.")
    }

    let runIDString = try statement.columnText(
      at: 1,
      maximumBytes: configuration.maximumTextBytes
    )
    guard let runUUID = UUID(uuidString: runIDString) else {
      throw SQLiteAgentEventJournalError.corruptRecord("run_id is not a UUID string.")
    }
    let storedRunID = AgentRunID(rawValue: runUUID)
    guard storedRunID == expectedRunID else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "A record was returned for the wrong run."
      )
    }

    let sequence = try statement.columnInt64(at: 2)
    guard sequence > 0 else {
      throw SQLiteAgentEventJournalError.corruptRecord("sequence is not positive.")
    }
    let timestampMicroseconds = try statement.columnInt64(at: 3)
    let recordSchemaVersion = try statement.columnInt64(at: 4)
    let kind = try statement.columnText(
      at: 5,
      maximumBytes: configuration.maximumTextBytes
    )
    let toolCallID = try statement.columnOptionalText(
      at: 6,
      maximumBytes: configuration.maximumTextBytes
    )
    let payload = try statement.columnBlob(
      at: 7,
      maximumBytes: configuration.maximumPayloadBytes
    )
    let event = try AgentEventCodec.decodeEvent(
      from: payload,
      schemaVersion: recordSchemaVersion
    )

    guard event.journalKind == kind else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "The event kind column does not match its payload."
      )
    }
    guard event.journalToolCallID?.rawValue == toolCallID else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "The tool_call_id column does not match its payload."
      )
    }

    let byteCounts = [
      eventIDString.utf8.count,
      runIDString.utf8.count,
      kind.utf8.count,
      toolCallID?.utf8.count ?? 0,
      payload.count,
    ]
    let byteCount = try byteCounts.reduce(0) { accumulated, next in
      let (sum, overflowed) = accumulated.addingReportingOverflow(next)
      guard !overflowed else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "A record's decoded byte count overflowed."
        )
      }
      return sum
    }

    return (
      AgentEventRecord(
        id: AgentEventID(rawValue: eventUUID),
        runID: storedRunID,
        sequence: UInt64(sequence),
        timestamp: AgentEventCodec.date(for: timestampMicroseconds),
        schemaVersion: AgentEventCodec.recordSchemaVersion,
        event: event
      ),
      byteCount
    )
  }
}
