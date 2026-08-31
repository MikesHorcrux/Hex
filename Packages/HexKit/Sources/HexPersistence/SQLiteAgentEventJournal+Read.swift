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
    if let sequence, sequence > UInt64(Int64.max) {
      return []
    }

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
    try statement.bind(Int64(sequence ?? 0), at: 2)
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
