extension SQLiteJournalMigrator {
  static let tasksSQL = """
    CREATE TABLE agent_tasks (
      id TEXT PRIMARY KEY NOT NULL,
      phase TEXT NOT NULL,
      revision INTEGER NOT NULL CHECK (revision > 0),
      payload BLOB NOT NULL
    )
    """
  static let taskAttemptsSQL = """
    CREATE TABLE agent_task_attempts (
      task_id TEXT NOT NULL,
      run_id TEXT PRIMARY KEY NOT NULL,
      attempt INTEGER NOT NULL CHECK (attempt > 0),
      UNIQUE (task_id, attempt),
      FOREIGN KEY (task_id) REFERENCES agent_tasks(id)
    )
    """
  static let taskEffectsSQL = """
    CREATE TABLE agent_task_effects (
      run_id TEXT NOT NULL,
      call_id TEXT NOT NULL,
      fingerprint BLOB NOT NULL,
      result BLOB,
      PRIMARY KEY (run_id, call_id),
      FOREIGN KEY (run_id) REFERENCES runs(run_id)
    )
    """
  static let taskEffectsIndexSQL = """
    CREATE INDEX agent_task_effects_fingerprint_idx ON agent_task_effects (fingerprint, run_id)
    """
  static func createVersionFive(connection: SQLiteConnection) throws {
    try connection.execute(tasksSQL)
    try connection.execute(taskEffectsSQL)
    try connection.execute(taskEffectsIndexSQL)
    try connection.execute(taskAttemptsSQL)
    try connection.execute("PRAGMA user_version = 5")
  }
  static var taskSchemaObjects: [String] {
    [
      schemaObjectKey(
        type: "table", name: "agent_task_effects", table: "agent_task_effects", sql: taskEffectsSQL),
      schemaObjectKey(
        type: "index", name: "sqlite_autoindex_agent_task_effects_1", table: "agent_task_effects",
        sql: nil),
      schemaObjectKey(
        type: "index", name: "agent_task_effects_fingerprint_idx", table: "agent_task_effects",
        sql: taskEffectsIndexSQL),
      schemaObjectKey(type: "table", name: "agent_tasks", table: "agent_tasks", sql: tasksSQL),
      schemaObjectKey(
        type: "index", name: "sqlite_autoindex_agent_tasks_1", table: "agent_tasks", sql: nil),
      schemaObjectKey(
        type: "table", name: "agent_task_attempts", table: "agent_task_attempts",
        sql: taskAttemptsSQL),
      schemaObjectKey(
        type: "index", name: "sqlite_autoindex_agent_task_attempts_1", table: "agent_task_attempts",
        sql: nil),
      schemaObjectKey(
        type: "index", name: "sqlite_autoindex_agent_task_attempts_2", table: "agent_task_attempts",
        sql: nil),
    ]
  }
}
