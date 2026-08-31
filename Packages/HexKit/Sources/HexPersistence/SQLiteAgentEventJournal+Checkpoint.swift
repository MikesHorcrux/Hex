import Foundation
import HexCore

extension SQLiteAgentEventJournal {
  public func writeCheckpoint(
    for runID: AgentRunID,
    through sequence: UInt64,
    snapshot: JSONValue
  ) async throws -> AgentJournalCheckpoint {
    try Task.checkCancellation()
    guard sequence > 0, sequence <= UInt64(Int64.max) else {
      throw SQLiteAgentEventJournalError.checkpointSequenceMissing(
        runID: runID,
        sequence: sequence
      )
    }

    let connection = try requireConnection()
    return try connection.withImmediateTransaction {
      try Task.checkCancellation()
      try SQLiteJournalMigrator.validateSchemaDefinition(
        connection: connection,
        maximumTextBytes: configuration.maximumTextBytes
      )
      try validateWholeJournalIntegrity(connection: connection)
      guard try eventExists(for: runID, sequence: sequence, connection: connection) else {
        throw SQLiteAgentEventJournalError.checkpointSequenceMissing(
          runID: runID,
          sequence: sequence
        )
      }

      if let existing = try checkpoint(
        for: runID,
        sequence: sequence,
        connection: connection
      ) {
        guard existing.snapshot == snapshot else {
          throw SQLiteAgentEventJournalError.checkpointConflict(
            runID: runID,
            sequence: sequence
          )
        }
        return existing
      }

      let timestampMicroseconds = try AgentEventCodec.microseconds(for: configuration.clock())
      let checkpoint = AgentJournalCheckpoint(
        runID: runID,
        throughSequence: sequence,
        createdAt: AgentEventCodec.date(for: timestampMicroseconds),
        schemaVersion: AgentEventCodec.checkpointSchemaVersion,
        snapshot: snapshot
      )
      let payload = try AgentEventCodec.encode(snapshot: snapshot)
      guard payload.count <= configuration.maximumPayloadBytes else {
        throw SQLiteAgentEventJournalError.payloadTooLarge(
          actual: payload.count,
          maximum: configuration.maximumPayloadBytes
        )
      }
      let insert = try connection.prepare(
        """
        INSERT INTO journal_checkpoints (
          run_id, through_sequence, created_at_us, checkpoint_schema_version, snapshot
        ) VALUES (?, ?, ?, ?, ?)
        """
      )
      try insert.bind(runID.description, at: 1)
      try insert.bind(Int64(sequence), at: 2)
      try insert.bind(timestampMicroseconds, at: 3)
      try insert.bind(Int64(AgentEventCodec.checkpointSchemaVersion), at: 4)
      try insert.bind(payload, at: 5)
      guard try insert.step() == .done else {
        throw SQLiteAgentEventJournalError.corruptSchema(
          "Inserting a checkpoint did not complete."
        )
      }
      return checkpoint
    }
  }

  public func latestCheckpoint(
    for runID: AgentRunID
  ) async throws -> AgentJournalCheckpoint? {
    try Task.checkCancellation()
    let connection = try requireConnection()
    return try connection.withDeferredTransaction {
      try Task.checkCancellation()
      try SQLiteJournalMigrator.validateSchemaDefinition(
        connection: connection,
        maximumTextBytes: configuration.maximumTextBytes
      )
      let counts = try checkpointIntegrityCounts(for: runID, connection: connection)
      guard counts.runCount == 1 else {
        guard
          counts.runCount == 0,
          counts.eventCount == 0,
          counts.checkpointCount == 0
        else {
          throw SQLiteAgentEventJournalError.corruptRecord(
            "Checkpoint or event state exists without exactly one run record."
          )
        }
        try validateWholeJournalIntegrity(connection: connection)
        return nil
      }
      guard counts.eventCount > 0, counts.orphanCheckpointCount == 0 else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "The run or one of its checkpoints references missing event state."
        )
      }
      try validateWholeJournalIntegrity(connection: connection)
      guard counts.checkpointCount > 0 else {
        return nil
      }

      let statement = try connection.prepare(
        """
        SELECT run_id, through_sequence, created_at_us, checkpoint_schema_version, snapshot
        FROM journal_checkpoints
        WHERE run_id = ?
        ORDER BY through_sequence DESC
        LIMIT 1
        """
      )
      try statement.bind(runID.description, at: 1)
      guard try statement.step() == .row else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "Checkpoint rows disappeared inside a stable read snapshot."
        )
      }
      let checkpoint = try decodeCheckpoint(from: statement, expectedRunID: runID)
      guard
        try eventExists(
          for: runID,
          sequence: checkpoint.throughSequence,
          connection: connection
        )
      else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "A checkpoint references a missing event sequence."
        )
      }
      try Task.checkCancellation()
      return checkpoint
    }
  }

  private func checkpointIntegrityCounts(
    for runID: AgentRunID,
    connection: SQLiteConnection
  ) throws -> (
    runCount: Int64,
    eventCount: Int64,
    checkpointCount: Int64,
    orphanCheckpointCount: Int64
  ) {
    let statement = try connection.prepare(
      """
      SELECT
        (SELECT COUNT(*) FROM runs WHERE run_id = ?),
        (SELECT COUNT(*) FROM event_records WHERE run_id = ?),
        (SELECT COUNT(*) FROM journal_checkpoints WHERE run_id = ?),
        (SELECT COUNT(*)
         FROM journal_checkpoints AS c
         LEFT JOIN event_records AS e
           ON e.run_id = c.run_id AND e.sequence = c.through_sequence
         WHERE c.run_id = ? AND e.run_id IS NULL)
      """
    )
    for index in 1...4 {
      try statement.bind(runID.description, at: Int32(index))
    }
    guard try statement.step() == .row else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "Checkpoint integrity accounting returned no row."
      )
    }
    return (
      runCount: try statement.columnInt64(at: 0),
      eventCount: try statement.columnInt64(at: 1),
      checkpointCount: try statement.columnInt64(at: 2),
      orphanCheckpointCount: try statement.columnInt64(at: 3)
    )
  }

  private func eventExists(
    for runID: AgentRunID,
    sequence: UInt64,
    connection: SQLiteConnection
  ) throws -> Bool {
    let statement = try connection.prepare(
      """
      SELECT 1 FROM event_records
      WHERE run_id = ? AND sequence = ?
      LIMIT 1
      """
    )
    try statement.bind(runID.description, at: 1)
    try statement.bind(Int64(sequence), at: 2)
    return try statement.step() == .row
  }

  private func checkpoint(
    for runID: AgentRunID,
    sequence: UInt64,
    connection: SQLiteConnection
  ) throws -> AgentJournalCheckpoint? {
    let statement = try connection.prepare(
      """
      SELECT run_id, through_sequence, created_at_us, checkpoint_schema_version, snapshot
      FROM journal_checkpoints
      WHERE run_id = ? AND through_sequence = ?
      """
    )
    try statement.bind(runID.description, at: 1)
    try statement.bind(Int64(sequence), at: 2)
    guard try statement.step() == .row else {
      return nil
    }
    return try decodeCheckpoint(from: statement, expectedRunID: runID)
  }

  private func decodeCheckpoint(
    from statement: SQLiteStatement,
    expectedRunID: AgentRunID
  ) throws -> AgentJournalCheckpoint {
    try decodeCheckpointWithByteCount(
      from: statement,
      expectedRunID: expectedRunID
    ).checkpoint
  }

  func decodeCheckpointWithByteCount(
    from statement: SQLiteStatement,
    expectedRunID: AgentRunID
  ) throws -> (checkpoint: AgentJournalCheckpoint, byteCount: Int) {
    let runIDString = try statement.columnText(
      at: 0,
      maximumBytes: configuration.maximumTextBytes
    )
    guard let runUUID = UUID(uuidString: runIDString) else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "A checkpoint run_id is not a UUID string."
      )
    }
    guard runIDString == runUUID.uuidString else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "A checkpoint run_id is not stored as canonical UUID text."
      )
    }
    let runID = AgentRunID(rawValue: runUUID)
    guard runID == expectedRunID else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "A checkpoint was returned for the wrong run."
      )
    }
    let sequence = try statement.columnInt64(at: 1)
    guard sequence > 0 else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "A checkpoint sequence is not positive."
      )
    }
    let timestampMicroseconds = try statement.columnInt64(at: 2)
    let schemaVersion = try statement.columnInt64(at: 3)
    let payload = try statement.columnBlob(
      at: 4,
      maximumBytes: configuration.maximumPayloadBytes
    )
    let snapshot = try AgentEventCodec.decodeSnapshot(
      from: payload,
      schemaVersion: schemaVersion
    )
    guard try AgentEventCodec.encode(snapshot: snapshot) == payload else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "The checkpoint snapshot is not canonical schema-version-one JSON."
      )
    }
    return (
      AgentJournalCheckpoint(
        runID: runID,
        throughSequence: UInt64(sequence),
        createdAt: AgentEventCodec.date(for: timestampMicroseconds),
        schemaVersion: AgentEventCodec.checkpointSchemaVersion,
        snapshot: snapshot
      ),
      runIDString.utf8.count + payload.count
    )
  }
}
