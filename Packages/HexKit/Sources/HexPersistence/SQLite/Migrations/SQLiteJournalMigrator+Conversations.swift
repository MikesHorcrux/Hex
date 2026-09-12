extension SQLiteJournalMigrator {
  static let conversationDocumentsSQL = """
    CREATE TABLE conversation_documents (
      id TEXT PRIMARY KEY NOT NULL,
      title TEXT NOT NULL,
      created_at_us INTEGER NOT NULL,
      updated_at_us INTEGER NOT NULL,
      archived_at_us INTEGER,
      revision INTEGER NOT NULL CHECK (revision > 0),
      state BLOB NOT NULL,
      next_sequence INTEGER NOT NULL CHECK (next_sequence > 0),
      last_operation TEXT NOT NULL,
      operation_hash BLOB NOT NULL,
      import_id TEXT
    )
    """
  static let conversationEntriesSQL = """
    CREATE TABLE conversation_entries (
      conversation_id TEXT NOT NULL,
      id TEXT NOT NULL,
      kind TEXT NOT NULL CHECK (kind IN ('display', 'message', 'exchange', 'compaction')),
      sequence INTEGER NOT NULL CHECK (sequence > 0),
      payload BLOB NOT NULL,
      search_text TEXT NOT NULL,
      PRIMARY KEY (conversation_id, id),
      UNIQUE (conversation_id, sequence),
      FOREIGN KEY (conversation_id) REFERENCES conversation_documents(id) ON DELETE CASCADE
    )
    """
  static let conversationSettingsSQL = """
    CREATE TABLE conversation_settings (
      key TEXT PRIMARY KEY NOT NULL,
      value TEXT NOT NULL
    )
    """
  static let conversationOrderSQL = """
    CREATE INDEX conversation_documents_order_idx
    ON conversation_documents (import_id, updated_at_us DESC, id DESC)
    """
  static let conversationEntryOrderSQL = """
    CREATE INDEX conversation_entries_kind_sequence_idx
    ON conversation_entries (conversation_id, kind, sequence DESC)
    """

  static let runValidationSQL = """
    CREATE TABLE run_validation (
      run_id TEXT COLLATE NOCASE PRIMARY KEY NOT NULL,
      last_event_id TEXT NOT NULL,
      state BLOB NOT NULL,
      checksum BLOB NOT NULL,
      FOREIGN KEY (run_id) REFERENCES runs(run_id) ON DELETE CASCADE
    )
    """
  static let openRunsSQL = """
    CREATE INDEX runs_open_idx ON runs (run_id) WHERE terminal_sequence IS NULL
    """

  static func createVersionFour(connection: SQLiteConnection) throws {
    for sql in [
      conversationDocumentsSQL, conversationEntriesSQL, conversationSettingsSQL,
      conversationOrderSQL, conversationEntryOrderSQL, runValidationSQL, openRunsSQL,
    ] {
      try connection.execute(sql)
    }
    try connection.execute("PRAGMA user_version = 4")
  }

  static var conversationSchemaObjects: [String] {
    [
      schemaObjectKey(
        type: "table", name: "run_validation", table: "run_validation", sql: runValidationSQL),
      schemaObjectKey(
        type: "index", name: "sqlite_autoindex_run_validation_1", table: "run_validation", sql: nil),
      schemaObjectKey(type: "index", name: "runs_open_idx", table: "runs", sql: openRunsSQL),
      schemaObjectKey(
        type: "table", name: "conversation_documents",
        table: "conversation_documents", sql: conversationDocumentsSQL),
      schemaObjectKey(
        type: "table", name: "conversation_entries",
        table: "conversation_entries", sql: conversationEntriesSQL),
      schemaObjectKey(
        type: "table", name: "conversation_settings",
        table: "conversation_settings", sql: conversationSettingsSQL),
      schemaObjectKey(
        type: "index", name: "conversation_documents_order_idx",
        table: "conversation_documents", sql: conversationOrderSQL),
      schemaObjectKey(
        type: "index", name: "conversation_entries_kind_sequence_idx",
        table: "conversation_entries", sql: conversationEntryOrderSQL),
      schemaObjectKey(
        type: "index", name: "sqlite_autoindex_conversation_documents_1",
        table: "conversation_documents", sql: nil),
      schemaObjectKey(
        type: "index", name: "sqlite_autoindex_conversation_entries_1",
        table: "conversation_entries", sql: nil),
      schemaObjectKey(
        type: "index", name: "sqlite_autoindex_conversation_entries_2",
        table: "conversation_entries", sql: nil),
      schemaObjectKey(
        type: "index", name: "sqlite_autoindex_conversation_settings_1",
        table: "conversation_settings", sql: nil),
    ]
  }
}
