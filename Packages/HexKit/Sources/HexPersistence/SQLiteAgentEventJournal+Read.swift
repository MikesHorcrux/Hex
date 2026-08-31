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
      try validateRunIntegrity(integrity, for: runID, connection: connection)

      guard sequence ?? 0 <= UInt64(Int64.max) else {
        return []
      }
      let records = try readPage(
        for: runID,
        after: Int64(sequence ?? 0),
        limit: limit,
        connection: connection
      )
      try validatePage(
        records,
        after: Int64(sequence ?? 0),
        limit: limit,
        integrity: integrity
      )
      try Task.checkCancellation()
      return records
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
    for runID: AgentRunID,
    connection: SQLiteConnection
  ) throws {
    guard
      integrity.recordCount > 0,
      integrity.minimumSequence == 1,
      let maximumSequence = integrity.maximumSequence,
      maximumSequence > 0,
      maximumSequence == integrity.recordCount
    else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "The run's durable sequences are empty, gapped, or noncontiguous."
      )
    }
    guard integrity.runStartedKindCount == 1 else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "The run must contain exactly one runStarted record."
      )
    }

    let firstRecord = try requiredRecord(
      for: runID,
      sequence: 1,
      connection: connection
    )
    guard firstRecord.event.startsRun else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "The run's first durable record is not runStarted."
      )
    }
    let lastRecord =
      maximumSequence == 1
      ? firstRecord
      : try requiredRecord(
        for: runID,
        sequence: maximumSequence,
        connection: connection
      )

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
        lastRecord.event.terminatesRun
      else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "The run's terminal metadata contradicts its durable terminal record."
        )
      }
    } else {
      guard
        maximumSequence < Int64.max,
        integrity.terminalKindCount == 0,
        !lastRecord.event.terminatesRun
      else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "A nonterminal run contains terminal data or an exhausted sequence."
        )
      }
    }
  }

  private func requiredRecord(
    for runID: AgentRunID,
    sequence: Int64,
    connection: SQLiteConnection
  ) throws -> AgentEventRecord {
    let statement = try connection.prepare(
      """
      SELECT event_id, run_id, sequence, timestamp_us, record_schema_version, kind, tool_call_id,
             payload
      FROM event_records
      WHERE run_id = ? AND sequence = ?
      LIMIT 1
      """
    )
    try statement.bind(runID.description, at: 1)
    try statement.bind(sequence, at: 2)
    guard try statement.step() == .row else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "A required boundary record is missing."
      )
    }
    return try decodeRecord(from: statement, expectedRunID: runID).record
  }

  private func readPage(
    for runID: AgentRunID,
    after sequence: Int64,
    limit: Int,
    connection: SQLiteConnection
  ) throws -> [AgentEventRecord] {
    let statement = try connection.prepare(
      """
      SELECT event_id, run_id, sequence, timestamp_us, record_schema_version, kind, tool_call_id,
             payload
      FROM event_records
      WHERE run_id = ? AND sequence > ?
      ORDER BY sequence ASC
      LIMIT ?
      """
    )
    try statement.bind(runID.description, at: 1)
    try statement.bind(sequence, at: 2)
    try statement.bind(Int64(limit), at: 3)

    var records: [AgentEventRecord] = []
    records.reserveCapacity(min(limit, 256))
    var decodedBytes = 0
    while true {
      try Task.checkCancellation()
      let stepResult = try statement.step()
      try Task.checkCancellation()
      guard stepResult == .row else {
        break
      }
      let decoded = try decodeRecord(from: statement, expectedRunID: runID)
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
      records.append(decoded.record)
    }
    return records
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
    let available = max(0, maximumSequence - sequence)
    let expectedCount = min(limit, Int(available))
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
