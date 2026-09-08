import Foundation

enum SQLiteJournalMigrator {
  static let currentSchemaVersion = 5
  static let versionOneRunsTableSQL =
    """
    CREATE TABLE runs (
      run_id TEXT PRIMARY KEY NOT NULL,
      next_sequence INTEGER NOT NULL,
      terminal_sequence INTEGER,
      created_at_us INTEGER NOT NULL,
      updated_at_us INTEGER NOT NULL
    )
    """
  static let versionOneEventRecordsTableSQL =
    """
    CREATE TABLE event_records (
      event_id TEXT NOT NULL UNIQUE,
      run_id TEXT NOT NULL,
      sequence INTEGER NOT NULL,
      timestamp_us INTEGER NOT NULL,
      record_schema_version INTEGER NOT NULL,
      kind TEXT NOT NULL,
      tool_call_id TEXT,
      payload BLOB NOT NULL,
      PRIMARY KEY (run_id, sequence),
      FOREIGN KEY (run_id) REFERENCES runs(run_id) ON DELETE CASCADE
    )
    """
  static let versionTwoCheckpointsTableSQL =
    """
    CREATE TABLE journal_checkpoints (
      run_id TEXT NOT NULL,
      through_sequence INTEGER NOT NULL,
      created_at_us INTEGER NOT NULL,
      checkpoint_schema_version INTEGER NOT NULL,
      snapshot BLOB NOT NULL,
      PRIMARY KEY (run_id, through_sequence),
      FOREIGN KEY (run_id) REFERENCES runs(run_id) ON DELETE CASCADE
    )
    """
  static let runsTableSQL =
    """
    CREATE TABLE runs (
      run_id TEXT COLLATE NOCASE PRIMARY KEY NOT NULL CHECK (
        length(run_id) = 36 AND run_id = upper(run_id) AND
        substr(run_id, 9, 1) = '-' AND substr(run_id, 14, 1) = '-' AND
        substr(run_id, 19, 1) = '-' AND substr(run_id, 24, 1) = '-' AND
        length(replace(run_id, '-', '')) = 32 AND
        replace(run_id, '-', '') NOT GLOB '*[^0-9A-F]*'
      ),
      next_sequence INTEGER NOT NULL,
      terminal_sequence INTEGER,
      created_at_us INTEGER NOT NULL,
      updated_at_us INTEGER NOT NULL
    )
    """
  static let eventRecordsTableSQL =
    """
    CREATE TABLE event_records (
      event_id TEXT COLLATE NOCASE NOT NULL UNIQUE CHECK (
        length(event_id) = 36 AND event_id = upper(event_id) AND
        substr(event_id, 9, 1) = '-' AND substr(event_id, 14, 1) = '-' AND
        substr(event_id, 19, 1) = '-' AND substr(event_id, 24, 1) = '-' AND
        length(replace(event_id, '-', '')) = 32 AND
        replace(event_id, '-', '') NOT GLOB '*[^0-9A-F]*'
      ),
      run_id TEXT COLLATE NOCASE NOT NULL CHECK (
        length(run_id) = 36 AND run_id = upper(run_id) AND
        substr(run_id, 9, 1) = '-' AND substr(run_id, 14, 1) = '-' AND
        substr(run_id, 19, 1) = '-' AND substr(run_id, 24, 1) = '-' AND
        length(replace(run_id, '-', '')) = 32 AND
        replace(run_id, '-', '') NOT GLOB '*[^0-9A-F]*'
      ),
      sequence INTEGER NOT NULL,
      timestamp_us INTEGER NOT NULL,
      record_schema_version INTEGER NOT NULL,
      kind TEXT NOT NULL,
      tool_call_id TEXT,
      payload BLOB NOT NULL,
      PRIMARY KEY (run_id, sequence),
      FOREIGN KEY (run_id) REFERENCES runs(run_id) ON DELETE CASCADE
    )
    """
  static let checkpointsTableSQL =
    """
    CREATE TABLE journal_checkpoints (
      run_id TEXT COLLATE NOCASE NOT NULL CHECK (
        length(run_id) = 36 AND run_id = upper(run_id) AND
        substr(run_id, 9, 1) = '-' AND substr(run_id, 14, 1) = '-' AND
        substr(run_id, 19, 1) = '-' AND substr(run_id, 24, 1) = '-' AND
        length(replace(run_id, '-', '')) = 32 AND
        replace(run_id, '-', '') NOT GLOB '*[^0-9A-F]*'
      ),
      through_sequence INTEGER NOT NULL,
      created_at_us INTEGER NOT NULL,
      checkpoint_schema_version INTEGER NOT NULL,
      snapshot BLOB NOT NULL,
      PRIMARY KEY (run_id, through_sequence),
      FOREIGN KEY (run_id) REFERENCES runs(run_id) ON DELETE CASCADE
    )
    """
  static let metadataIndexSQL =
    """
    CREATE INDEX event_records_run_kind_tool_call_idx
    ON event_records (run_id, kind, tool_call_id)
    """

  static func prepare(
    connection: SQLiteConnection,
    configuration: SQLiteAgentEventJournalConfiguration,
    beforeCommit: () throws -> Void,
    afterCommit: () throws -> Void,
    validateMigratedData: () throws -> Void
  ) throws {
    let foundVersion = try schemaVersion(connection: connection)
    guard foundVersion <= currentSchemaVersion else {
      throw SQLiteAgentEventJournalError.futureSchemaVersion(
        found: foundVersion,
        supported: currentSchemaVersion
      )
    }

    try configure(
      connection: connection,
      busyTimeoutMilliseconds: configuration.busyTimeoutMilliseconds,
      maximumTextBytes: configuration.maximumTextBytes
    )
    try migrate(
      connection: connection,
      from: foundVersion,
      configuration: configuration,
      beforeCommit: beforeCommit,
      afterCommit: afterCommit,
      validateMigratedData: validateMigratedData
    )
    try validateSchema(
      connection: connection,
      maximumTextBytes: configuration.maximumTextBytes
    )
  }

  static func schemaVersion(connection: SQLiteConnection) throws -> Int {
    let value = try connection.scalarInt64("PRAGMA user_version")
    guard value >= 0, value <= Int64(Int.max) else {
      throw SQLiteAgentEventJournalError.corruptSchema("PRAGMA user_version is invalid.")
    }
    return Int(value)
  }

  private static func configure(
    connection: SQLiteConnection,
    busyTimeoutMilliseconds: Int,
    maximumTextBytes: Int
  ) throws {
    try connection.execute("PRAGMA foreign_keys = ON")
    guard try connection.scalarInt64("PRAGMA foreign_keys") == 1 else {
      throw SQLiteAgentEventJournalError.corruptSchema("foreign_keys could not be enabled.")
    }

    try connection.execute("PRAGMA trusted_schema = OFF")
    guard try connection.scalarInt64("PRAGMA trusted_schema") == 0 else {
      throw SQLiteAgentEventJournalError.corruptSchema("trusted_schema could not be disabled.")
    }

    let journalMode = try connection.scalarText(
      "PRAGMA journal_mode = WAL",
      maximumBytes: maximumTextBytes
    ).lowercased()
    guard journalMode == "wal" else {
      throw SQLiteAgentEventJournalError.corruptSchema(
        "journal_mode is \(journalMode), not WAL."
      )
    }

    try connection.execute("PRAGMA synchronous = FULL")
    guard try connection.scalarInt64("PRAGMA synchronous") == 2 else {
      throw SQLiteAgentEventJournalError.corruptSchema("synchronous could not be set to FULL.")
    }

    guard try connection.scalarInt64("PRAGMA busy_timeout") == Int64(busyTimeoutMilliseconds) else {
      throw SQLiteAgentEventJournalError.corruptSchema("busy_timeout was not applied.")
    }
  }

  private static func migrate(
    connection: SQLiteConnection,
    from version: Int,
    configuration: SQLiteAgentEventJournalConfiguration,
    beforeCommit: () throws -> Void,
    afterCommit: () throws -> Void,
    validateMigratedData: () throws -> Void
  ) throws {
    switch version {
    case currentSchemaVersion:
      return
    case 0:
      let userTable = try connection.prepare(
        """
        SELECT 1 FROM sqlite_master
        WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
        LIMIT 1
        """
      )
      guard try userTable.step() == .done else {
        throw SQLiteAgentEventJournalError.corruptSchema(
          "A version-zero database already contains application tables."
        )
      }
      try connection.withImmediateTransaction(
        beforeCommit: beforeCommit,
        afterCommit: afterCommit
      ) {
        try createVersionOne(connection: connection)
        try connection.execute("PRAGMA user_version = 1")
        try createVersionTwo(connection: connection)
        try connection.execute("PRAGMA user_version = 2")
        try createVersionThree(connection: connection, configuration: configuration)
        try connection.execute("PRAGMA user_version = 3")
        try createVersionFour(connection: connection)
        try createVersionFive(connection: connection)
        try validateSchema(
          connection: connection,
          maximumTextBytes: configuration.maximumTextBytes
        )
        try validateMigratedData()
      }
    case 1:
      try connection.withImmediateTransaction(
        beforeCommit: beforeCommit,
        afterCommit: afterCommit
      ) {
        try createVersionTwo(connection: connection)
        try connection.execute("PRAGMA user_version = 2")
        try createVersionThree(connection: connection, configuration: configuration)
        try connection.execute("PRAGMA user_version = 3")
        try createVersionFour(connection: connection)
        try createVersionFive(connection: connection)
        try validateSchema(
          connection: connection,
          maximumTextBytes: configuration.maximumTextBytes
        )
        try validateMigratedData()
      }
    case 2:
      try connection.withImmediateTransaction(
        beforeCommit: beforeCommit,
        afterCommit: afterCommit
      ) {
        try createVersionThree(connection: connection, configuration: configuration)
        try connection.execute("PRAGMA user_version = 3")
        try createVersionFour(connection: connection)
        try createVersionFive(connection: connection)
        try validateSchema(
          connection: connection,
          maximumTextBytes: configuration.maximumTextBytes
        )
        try validateMigratedData()
      }
    case 3:
      try connection.withImmediateTransaction(beforeCommit: beforeCommit, afterCommit: afterCommit)
      {
        try validateSchemaObjects(
          runsSQL: runsTableSQL, eventRecordsSQL: eventRecordsTableSQL,
          checkpointsSQL: checkpointsTableSQL, connection: connection,
          maximumTextBytes: configuration.maximumTextBytes)
        try createVersionFour(connection: connection)
        try createVersionFive(connection: connection)
        try validateSchema(connection: connection, maximumTextBytes: configuration.maximumTextBytes)
        try validateMigratedData()
      }
    case 4:
      try connection.withImmediateTransaction(beforeCommit: beforeCommit, afterCommit: afterCommit)
      {
        try validateSchemaObjects(
          runsSQL: runsTableSQL, eventRecordsSQL: eventRecordsTableSQL,
          checkpointsSQL: checkpointsTableSQL, connection: connection,
          maximumTextBytes: configuration.maximumTextBytes)
        try createVersionFive(connection: connection)
        try validateSchema(connection: connection, maximumTextBytes: configuration.maximumTextBytes)
        try validateMigratedData()
      }
    default:
      throw SQLiteAgentEventJournalError.corruptSchema(
        "Unsupported historical schema version \(version)."
      )
    }
  }

  private static func createVersionOne(connection: SQLiteConnection) throws {
    try connection.execute(versionOneRunsTableSQL)
    try connection.execute(versionOneEventRecordsTableSQL)
  }

  private static func createVersionTwo(connection: SQLiteConnection) throws {
    try connection.execute(versionTwoCheckpointsTableSQL)
    try connection.execute(metadataIndexSQL)
  }

  private static func createVersionThree(
    connection: SQLiteConnection,
    configuration: SQLiteAgentEventJournalConfiguration
  ) throws {
    try validateVersionTwoSchema(
      connection: connection,
      maximumTextBytes: configuration.maximumTextBytes
    )
    try SQLiteJournalMigrationValidator.validateVersionTwoData(
      connection: connection,
      configuration: configuration
    )

    try connection.execute("DROP INDEX event_records_run_kind_tool_call_idx")
    try connection.execute("ALTER TABLE journal_checkpoints RENAME TO journal_checkpoints_v2")
    try connection.execute("ALTER TABLE event_records RENAME TO event_records_v2")
    try connection.execute("ALTER TABLE runs RENAME TO runs_v2")
    try connection.execute(runsTableSQL)
    try connection.execute(eventRecordsTableSQL)
    try connection.execute(checkpointsTableSQL)
    try connection.execute(metadataIndexSQL)
    try connection.execute(
      """
      INSERT INTO runs (run_id, next_sequence, terminal_sequence, created_at_us, updated_at_us)
      SELECT upper(run_id), next_sequence, terminal_sequence, created_at_us, updated_at_us
      FROM runs_v2
      """
    )
    try connection.execute(
      """
      INSERT INTO event_records (
        event_id, run_id, sequence, timestamp_us, record_schema_version, kind, tool_call_id, payload
      )
      SELECT upper(event_id), upper(run_id), sequence, timestamp_us, record_schema_version, kind,
             tool_call_id, payload
      FROM event_records_v2
      """
    )
    try connection.execute(
      """
      INSERT INTO journal_checkpoints (
        run_id, through_sequence, created_at_us, checkpoint_schema_version, snapshot
      )
      SELECT upper(run_id), through_sequence, created_at_us, checkpoint_schema_version, snapshot
      FROM journal_checkpoints_v2
      """
    )
    try connection.execute("DROP TABLE journal_checkpoints_v2")
    try connection.execute("DROP TABLE event_records_v2")
    try connection.execute("DROP TABLE runs_v2")
  }

}
