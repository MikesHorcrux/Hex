extension SQLiteJournalMigrator {
  static let processSessionsSQL = """
    CREATE TABLE process_sessions (
      id TEXT PRIMARY KEY NOT NULL,
      conversation_id TEXT NOT NULL,
      revision INTEGER NOT NULL,
      payload BLOB NOT NULL
    )
    """
  static let processOperationsSQL = """
    CREATE TABLE process_operations (
      id TEXT PRIMARY KEY NOT NULL,
      session_id TEXT NOT NULL,
      payload BLOB NOT NULL,
      FOREIGN KEY (session_id) REFERENCES process_sessions(id)
    )
    """
  static let processSegmentsSQL = """
    CREATE TABLE process_segments (
      session_id TEXT NOT NULL,
      offset INTEGER NOT NULL,
      byte_count INTEGER NOT NULL,
      payload BLOB NOT NULL,
      PRIMARY KEY (session_id, offset),
      FOREIGN KEY (session_id) REFERENCES process_sessions(id)
    )
    """
  static let codingBaselinesSQL =
    "CREATE TABLE coding_baselines (task_id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)"
  static let codingPatchesSQL =
    "CREATE TABLE coding_patches (id TEXT PRIMARY KEY NOT NULL, task_id TEXT NOT NULL, state TEXT NOT NULL, committed INTEGER NOT NULL, payload BLOB NOT NULL)"
  static func createVersionSeven(connection: SQLiteConnection) throws {
    try connection.execute(processSessionsSQL)
    try connection.execute(processOperationsSQL)
    try connection.execute(processSegmentsSQL)
    try connection.execute(codingBaselinesSQL)
    try connection.execute(codingPatchesSQL)
    try connection.execute("PRAGMA user_version = 7")
  }
  static var processSchemaObjects: [String] {
    [
      ("process_sessions", processSessionsSQL), ("process_operations", processOperationsSQL),
      ("process_segments", processSegmentsSQL), ("coding_baselines", codingBaselinesSQL),
      ("coding_patches", codingPatchesSQL),
    ].flatMap { name, sql in
      [
        schemaObjectKey(type: "table", name: name, table: name, sql: sql),
        schemaObjectKey(type: "index", name: "sqlite_autoindex_\(name)_1", table: name, sql: nil),
      ]
    }
  }
}
