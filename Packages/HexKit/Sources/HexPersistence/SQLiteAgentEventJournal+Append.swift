import HexCore

extension SQLiteAgentEventJournal {
  public func append(
    _ event: AgentEvent,
    to runID: AgentRunID
  ) async throws -> AgentEventRecord {
    try Task.checkCancellation()
    let connection = try requireConnection()
    return try withImmediateOwnedTransaction(connection: connection) {
      try Task.checkCancellation()
      try SQLiteJournalMigrator.validateSchemaDefinition(
        connection: connection,
        maximumTextBytes: configuration.maximumTextBytes
      )
      try validateWholeJournalIntegrity(connection: connection)
      let record = try appendInTransaction(event, to: runID, connection: connection)
      try validateAppendedRunLifecycle(for: runID, connection: connection)
      return record
    }
  }

  func appendInTransaction(
    _ event: AgentEvent,
    to runID: AgentRunID,
    connection: SQLiteConnection
  ) throws -> AgentEventRecord {
    try validateStoredText(runID.description)
    try validateStoredText(event.journalKind)
    if let toolCallID = event.journalToolCallID {
      try validateStoredText(toolCallID.rawValue)
    }

    let timestampMicroseconds = try AgentEventCodec.microseconds(for: configuration.clock())
    let timestamp = AgentEventCodec.date(for: timestampMicroseconds)
    let eventID = AgentEventID(rawValue: configuration.uuidGenerator())
    let runIDString = runID.description
    let sequence: Int64

    if event.startsRun {
      let existingRun = try connection.prepare(
        "SELECT 1 FROM runs WHERE run_id = ? LIMIT 1"
      )
      try existingRun.bind(runIDString, at: 1)
      if try existingRun.step() == .row {
        throw SQLiteAgentEventJournalError.duplicateRun(runID)
      }

      let insertRun = try connection.prepare(
        """
        INSERT INTO runs (
          run_id, next_sequence, terminal_sequence, created_at_us, updated_at_us
        ) VALUES (?, 2, NULL, ?, ?)
        """
      )
      try insertRun.bind(runIDString, at: 1)
      try insertRun.bind(timestampMicroseconds, at: 2)
      try insertRun.bind(timestampMicroseconds, at: 3)
      guard try insertRun.step() == .done else {
        throw SQLiteAgentEventJournalError.corruptSchema(
          "Inserting a run did not complete."
        )
      }
      sequence = 1
    } else {
      let selectRun = try connection.prepare(
        "SELECT next_sequence, terminal_sequence FROM runs WHERE run_id = ?"
      )
      try selectRun.bind(runIDString, at: 1)
      guard try selectRun.step() == .row else {
        throw SQLiteAgentEventJournalError.runNotFound(runID)
      }
      let nextSequence = try selectRun.columnInt64(at: 0)
      if try selectRun.columnOptionalInt64(at: 1) != nil {
        throw SQLiteAgentEventJournalError.runAlreadyTerminal(runID)
      }
      guard nextSequence > 0 else {
        throw SQLiteAgentEventJournalError.sequenceOverflow(runID)
      }
      guard nextSequence < Int64.max || event.terminatesRun else {
        throw SQLiteAgentEventJournalError.sequenceOverflow(runID)
      }

      sequence = nextSequence
      let followingSequence = nextSequence == Int64.max ? -1 : nextSequence + 1
      let updateRun = try connection.prepare(
        """
        UPDATE runs
        SET next_sequence = ?, updated_at_us = ?
        WHERE run_id = ? AND terminal_sequence IS NULL AND next_sequence = ?
        """
      )
      try updateRun.bind(followingSequence, at: 1)
      try updateRun.bind(timestampMicroseconds, at: 2)
      try updateRun.bind(runIDString, at: 3)
      try updateRun.bind(nextSequence, at: 4)
      guard try updateRun.step() == .done, try connection.changes() == 1 else {
        throw SQLiteAgentEventJournalError.corruptSchema(
          "The run sequence could not be advanced atomically."
        )
      }
    }

    let payload = try AgentEventCodec.encode(event: event)
    guard payload.count <= configuration.maximumPayloadBytes else {
      throw SQLiteAgentEventJournalError.payloadTooLarge(
        actual: payload.count,
        maximum: configuration.maximumPayloadBytes
      )
    }
    let insertEvent = try connection.prepare(
      """
      INSERT INTO event_records (
        event_id, run_id, sequence, timestamp_us, record_schema_version, kind, tool_call_id, payload
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """
    )
    try insertEvent.bind(eventID.description, at: 1)
    try insertEvent.bind(runIDString, at: 2)
    try insertEvent.bind(sequence, at: 3)
    try insertEvent.bind(timestampMicroseconds, at: 4)
    try insertEvent.bind(Int64(AgentEventCodec.recordSchemaVersion), at: 5)
    try insertEvent.bind(event.journalKind, at: 6)
    if let toolCallID = event.journalToolCallID {
      try insertEvent.bind(toolCallID.rawValue, at: 7)
    } else {
      try insertEvent.bindNull(at: 7)
    }
    try insertEvent.bind(payload, at: 8)
    guard try insertEvent.step() == .done else {
      throw SQLiteAgentEventJournalError.corruptSchema(
        "Inserting an event did not complete."
      )
    }

    if event.terminatesRun {
      let markTerminal = try connection.prepare(
        """
        UPDATE runs SET terminal_sequence = ?, updated_at_us = ?
        WHERE run_id = ? AND terminal_sequence IS NULL
        """
      )
      try markTerminal.bind(sequence, at: 1)
      try markTerminal.bind(timestampMicroseconds, at: 2)
      try markTerminal.bind(runIDString, at: 3)
      guard try markTerminal.step() == .done, try connection.changes() == 1 else {
        throw SQLiteAgentEventJournalError.corruptSchema(
          "The run could not be marked terminal atomically."
        )
      }
    }

    return AgentEventRecord(
      id: eventID,
      runID: runID,
      sequence: UInt64(sequence),
      timestamp: timestamp,
      schemaVersion: AgentEventCodec.recordSchemaVersion,
      event: event
    )
  }

  private func validateStoredText(_ value: String) throws {
    let byteCount = value.utf8.count
    guard byteCount <= configuration.maximumTextBytes else {
      throw SQLiteAgentEventJournalError.textTooLarge(
        actual: byteCount,
        maximum: configuration.maximumTextBytes
      )
    }
  }
}
