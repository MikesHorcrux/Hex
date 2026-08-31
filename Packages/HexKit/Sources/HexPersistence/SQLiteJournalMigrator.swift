import Foundation

enum SQLiteJournalMigrator {
  static let currentSchemaVersion = 2

  static func prepare(
    connection: SQLiteConnection,
    busyTimeoutMilliseconds: Int,
    maximumTextBytes: Int
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
      busyTimeoutMilliseconds: busyTimeoutMilliseconds,
      maximumTextBytes: maximumTextBytes
    )
    try migrate(connection: connection, from: foundVersion, maximumTextBytes: maximumTextBytes)
    try validateSchema(connection: connection, maximumTextBytes: maximumTextBytes)

    let quickCheck = try connection.scalarText(
      "PRAGMA quick_check",
      maximumBytes: maximumTextBytes
    )
    guard quickCheck == "ok" else {
      throw SQLiteAgentEventJournalError.corruptSchema(
        "SQLite quick_check returned \(quickCheck)."
      )
    }
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
    maximumTextBytes: Int
  ) throws {
    switch version {
    case currentSchemaVersion:
      return
    case 0:
      let userTableCount = try connection.scalarInt64(
        """
        SELECT COUNT(*) FROM sqlite_master
        WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
        """
      )
      guard userTableCount == 0 else {
        throw SQLiteAgentEventJournalError.corruptSchema(
          "A version-zero database already contains application tables."
        )
      }
      try connection.withImmediateTransaction {
        try createVersionOne(connection: connection)
        try connection.execute("PRAGMA user_version = 1")
        try createVersionTwo(connection: connection)
        try connection.execute("PRAGMA user_version = 2")
        try validateSchema(connection: connection, maximumTextBytes: maximumTextBytes)
      }
    case 1:
      try connection.withImmediateTransaction {
        try createVersionTwo(connection: connection)
        try connection.execute("PRAGMA user_version = 2")
        try validateSchema(connection: connection, maximumTextBytes: maximumTextBytes)
      }
    default:
      throw SQLiteAgentEventJournalError.corruptSchema(
        "Unsupported historical schema version \(version)."
      )
    }
  }

  private static func createVersionOne(connection: SQLiteConnection) throws {
    try connection.execute(
      """
      CREATE TABLE runs (
        run_id TEXT PRIMARY KEY NOT NULL,
        next_sequence INTEGER NOT NULL,
        terminal_sequence INTEGER,
        created_at_us INTEGER NOT NULL,
        updated_at_us INTEGER NOT NULL
      )
      """
    )
    try connection.execute(
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
    )
  }

  private static func createVersionTwo(connection: SQLiteConnection) throws {
    try connection.execute(
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
    )
    try connection.execute(
      """
      CREATE INDEX event_records_run_kind_tool_call_idx
      ON event_records (run_id, kind, tool_call_id)
      """
    )
  }

}
