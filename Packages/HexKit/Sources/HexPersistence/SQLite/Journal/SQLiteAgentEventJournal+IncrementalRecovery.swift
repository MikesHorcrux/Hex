import CryptoKit
import Foundation
import HexCore

extension SQLiteAgentEventJournal {
  /// This checkpoint is updated in the event's transaction, not by the app or by a later timer.
  /// It contains lifecycle validation state, never permission grants or permission decisions to replay.
  func saveRunValidation(
    _ state: SQLiteJournalActiveRunState, record: AgentEventRecord,
    connection: SQLiteConnection
  ) throws {
    if record.event.terminatesRun {
      let removal = try connection.prepare("DELETE FROM run_validation WHERE run_id = ?")
      try removal.bind(record.runID.description, at: 1)
      _ = try removal.step()
      return
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(state)
    guard payload.count <= 4 * 1_024 * 1_024 else {
      throw SQLiteAgentEventJournalError.payloadTooLarge(
        actual: payload.count,
        maximum: 4 * 1_024 * 1_024)
    }
    let event = try connection.prepare(
      "SELECT payload FROM event_records WHERE run_id = ? AND sequence = ?")
    try event.bind(record.runID.description, at: 1)
    try event.bind(Int64(record.sequence), at: 2)
    guard try event.step() == .row else { throw invalidRunValidation() }
    let eventPayload = try event.columnBlob(at: 0, maximumBytes: configuration.maximumPayloadBytes)
    let checksum = Data(SHA256.hash(data: payload + eventPayload))
    let statement = try connection.prepare(
      """
      INSERT INTO run_validation (run_id, last_event_id, state, checksum) VALUES (?, ?, ?, ?)
      ON CONFLICT (run_id) DO UPDATE SET last_event_id = excluded.last_event_id,
        state = excluded.state, checksum = excluded.checksum
      """)
    try statement.bind(record.runID.description, at: 1)
    try statement.bind(record.id.description, at: 2)
    try statement.bind(payload, at: 3)
    try statement.bind(checksum, at: 4)
    _ = try statement.step()
  }

  /// A schema upgrade streams existing active runs once, after the historical integrity audit.
  /// Subsequent opens read this checkpoint and boundary records only.
  func seedRunValidation(connection: SQLiteConnection) throws {
    let runs = try connection.prepare("SELECT run_id FROM runs WHERE terminal_sequence IS NULL")
    while try runs.step() == .row {
      try Task.checkCancellation()
      guard let id = UUID(uuidString: try runs.columnText(at: 0, maximumBytes: 36)) else {
        throw invalidRunValidation()
      }
      let runID = AgentRunID(rawValue: id)
      var state = try SQLiteJournalActiveRunState(runID: runID, configuration: configuration)
      let events = try connection.prepare(
        """
        SELECT event_id, run_id, sequence, timestamp_us, record_schema_version, kind, tool_call_id, payload
        FROM event_records WHERE run_id = ? ORDER BY sequence
        """)
      try events.bind(runID.description, at: 1)
      var last: AgentEventRecord?
      while try events.step() == .row {
        try Task.checkCancellation()
        let decoded = try decodeRecord(from: events, expectedRunID: runID)
        state = try state.appending(
          decoded.record, recordByteCount: decoded.byteCount,
          configuration: configuration)
        last = decoded.record
      }
      guard let last else { throw invalidRunValidation() }
      try saveRunValidation(state, record: last, connection: connection)
    }
  }

  func recoverIncrementally() throws -> [InterruptedAgentRun] {
    let connection = try requireConnection()
    let reports = try withImmediateOwnedTransaction(connection: connection) {
      let runs = try connection.prepare(
        """
        SELECT run_id FROM runs WHERE terminal_sequence IS NULL ORDER BY run_id LIMIT ?
        """)
      try runs.bind(Int64(configuration.maximumRecoveryRunCount + 1), at: 1)
      var ids: [AgentRunID] = []
      while try runs.step() == .row {
        guard ids.count < configuration.maximumRecoveryRunCount,
          let id = UUID(uuidString: try runs.columnText(at: 0, maximumBytes: 36))
        else {
          throw invalidRunValidation()
        }
        ids.append(AgentRunID(rawValue: id))
      }
      var reports: [InterruptedAgentRun] = []
      for runID in ids {
        try Task.checkCancellation()
        var state = try readRunValidation(runID, connection: connection)
        reports.append(.init(runID: runID, unresolvedToolCallIDs: state.unresolvedToolCallIDs))
        // These are non-execution receipts only. A checkpoint never authorizes re-executing a tool.
        for event in state.interruptedNonExecutionEvents + [SQLiteInterruptedRunTerminal.event] {
          let record = try appendInTransaction(event, to: runID, connection: connection)
          let decoded = try validateAppendedRecord(record, connection: connection)
          state = try state.appending(
            record, recordByteCount: decoded.byteCount,
            configuration: configuration)
          try saveRunValidation(state, record: record, connection: connection)
        }
      }
      return reports
    }
    integrityUsage = .zero
    integrityDataVersion = try currentDataVersion(connection: connection)
    activeRunStates.removeAll()
    return reports
  }

  func readRunValidation(_ runID: AgentRunID, connection: SQLiteConnection) throws
    -> SQLiteJournalActiveRunState
  {
    let statement = try connection.prepare(
      """
      SELECT r.next_sequence, v.last_event_id, v.state, v.checksum, e.event_id, e.payload
      FROM runs r JOIN run_validation v ON v.run_id = r.run_id
      JOIN event_records e ON e.run_id = r.run_id AND e.sequence = r.next_sequence - 1
      WHERE r.run_id = ? AND r.terminal_sequence IS NULL
      """)
    try statement.bind(runID.description, at: 1)
    guard try statement.step() == .row else { throw invalidRunValidation() }
    let next = try statement.columnInt64(at: 0)
    let payload = try statement.columnBlob(at: 2, maximumBytes: 4 * 1_024 * 1_024)
    let event = try statement.columnBlob(at: 5, maximumBytes: configuration.maximumPayloadBytes)
    guard next > 1,
      try statement.columnText(at: 1, maximumBytes: 36)
        == statement.columnText(at: 4, maximumBytes: 36),
      try statement.columnBlob(at: 3, maximumBytes: 32) == Data(SHA256.hash(data: payload + event))
    else {
      throw invalidRunValidation()
    }
    let state = try JSONDecoder().decode(SQLiteJournalActiveRunState.self, from: payload)
    guard state.matches(runID: runID, nextSequence: UInt64(next)) else {
      throw invalidRunValidation()
    }
    return state
  }

  private func invalidRunValidation() -> SQLiteAgentEventJournalError {
    .corruptRecord("The active run checkpoint does not match its committed event boundary.")
  }
}
