import Foundation
import HexCore

extension SQLiteAgentEventJournal {
  /// Reads indexed metadata and boundary records against the admitted integrity baseline. Unlike
  /// records(), this does not scan the run; external writers invalidate the baseline, never replace it.
  public func runSnapshot(for runID: AgentRunID) async throws -> AgentJournalRunSnapshot? {
    try Task.checkCancellation()
    let connection = try requireConnection()
    return try withDeferredOwnedTransaction(connection: connection) {
      try validateRecoveryReadBoundary(connection)
      let snapshot = try recoverySnapshot(for: runID, connection: connection)
      try Task.checkCancellation()
      return snapshot
    }
  }

  /// Returns a contiguous prefix bounded by both record count and serialized record bytes. A
  /// single record too large for the requested budget fails; it is never skipped or truncated.
  public func recoveryRecords(
    for runID: AgentRunID, after: UInt64, through: UInt64, limit: Int, maximumBytes: Int
  ) async throws -> [AgentEventRecord] {
    try Task.checkCancellation()
    guard (1...configuration.maximumReadLimit).contains(limit) else {
      throw SQLiteAgentEventJournalError.invalidReadLimit(
        requested: limit, maximum: configuration.maximumReadLimit)
    }
    guard after <= through, through > 0, through <= UInt64(Int64.max),
      maximumBytes > 0, maximumBytes <= configuration.maximumReadBytes
    else {
      throw SQLiteAgentEventJournalError.invalidConfiguration("Invalid recovery page bounds.")
    }
    let connection = try requireConnection()
    return try withDeferredOwnedTransaction(connection: connection) {
      try validateRecoveryReadBoundary(connection)
      guard let snapshot = try recoverySnapshot(for: runID, connection: connection) else {
        throw SQLiteAgentEventJournalError.runNotFound(runID)
      }
      guard through <= snapshot.latestSequence else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "The recovery cursor is ahead of durable history.")
      }
      if after == through { return [] }
      let statement = try connection.prepare(
        """
        SELECT event_id, run_id, sequence, timestamp_us, record_schema_version, kind, tool_call_id, payload
        FROM event_records WHERE run_id = ? AND sequence > ? AND sequence <= ?
        ORDER BY sequence ASC LIMIT ?
        """)
      try statement.bind(runID.description, at: 1)
      try statement.bind(Int64(after), at: 2)
      try statement.bind(Int64(through), at: 3)
      try statement.bind(Int64(limit), at: 4)
      var records: [AgentEventRecord] = []
      var encodedBytes = 0
      var stoppedAtByteLimit = false
      while try statement.step() == .row {
        try Task.checkCancellation()
        let record = try decodeRecord(from: statement, expectedRunID: runID).record
        guard record.sequence == after + UInt64(records.count) + 1,
          !record.event.startsRun || record.sequence == 1,
          !record.event.terminatesRun || record == snapshot.terminalRecord
        else {
          throw SQLiteAgentEventJournalError.corruptRecord(
            "Recovery records contradict the validated run boundaries.")
        }
        let bytes = try JSONEncoder().encode(record).count
        let (nextBytes, overflow) = encodedBytes.addingReportingOverflow(bytes)
        if overflow || nextBytes > maximumBytes {
          guard !records.isEmpty else {
            throw SQLiteAgentEventJournalError.readByteLimitExceeded(
              actual: overflow ? Int.max : nextBytes, maximum: maximumBytes)
          }
          stoppedAtByteLimit = true
          break
        }
        encodedBytes = nextBytes
        records.append(record)
      }
      let expectedCount = min(UInt64(limit), through - after)
      guard stoppedAtByteLimit || UInt64(records.count) == expectedCount else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "Recovery history contains a missing record.")
      }
      try Task.checkCancellation()
      return records
    }
  }

  private func validateRecoveryReadBoundary(_ connection: SQLiteConnection) throws {
    try Task.checkCancellation()
    try SQLiteJournalMigrator.validateSchemaDefinition(
      connection: connection, maximumTextBytes: configuration.maximumTextBytes)
    try validateIntegrityDataVersion(connection: connection)
  }

  private func recoverySnapshot(for runID: AgentRunID, connection: SQLiteConnection) throws
    -> AgentJournalRunSnapshot?
  {
    let metadata = try connection.prepare(
      "SELECT next_sequence, terminal_sequence FROM runs WHERE run_id = ? LIMIT 1")
    try metadata.bind(runID.description, at: 1)
    guard try metadata.step() == .row else { return nil }
    let next = try metadata.columnInt64(at: 0)
    let terminal = try metadata.columnOptionalInt64(at: 1)
    let first = try recoveryBoundaryRecord(for: runID, descending: false, connection: connection)
    let last = try recoveryBoundaryRecord(for: runID, descending: true, connection: connection)
    guard first.sequence == 1, first.event.startsRun, last.sequence <= UInt64(Int64.max),
      next == (last.sequence == UInt64(Int64.max) ? -1 : Int64(last.sequence) + 1),
      !last.event.startsRun || last.sequence == 1,
      (terminal != nil) == last.event.terminatesRun,
      terminal == nil || terminal == Int64(last.sequence)
    else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "Recovery metadata contradicts durable boundary records.")
    }
    return AgentJournalRunSnapshot(
      runID: runID, firstEventID: first.id, latestSequence: last.sequence,
      terminalRecord: terminal == nil ? nil : last)
  }

  private func recoveryBoundaryRecord(
    for runID: AgentRunID, descending: Bool, connection: SQLiteConnection
  ) throws -> AgentEventRecord {
    let direction = descending ? "DESC" : "ASC"
    let statement = try connection.prepare(
      """
      SELECT event_id, run_id, sequence, timestamp_us, record_schema_version, kind, tool_call_id, payload
      FROM event_records WHERE run_id = ? ORDER BY sequence \(direction) LIMIT 1
      """)
    try statement.bind(runID.description, at: 1)
    guard try statement.step() == .row else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "A recovery run has no durable boundary record.")
    }
    return try decodeRecord(from: statement, expectedRunID: runID).record
  }
}
