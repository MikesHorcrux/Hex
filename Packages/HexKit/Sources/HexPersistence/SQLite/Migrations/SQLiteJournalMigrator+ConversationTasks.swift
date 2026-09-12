import Foundation
import HexCore

extension SQLiteJournalMigrator {
  static let conversationTasksSQL = """
    CREATE TABLE conversation_tasks (
      task_id TEXT PRIMARY KEY NOT NULL,
      conversation_id TEXT NOT NULL,
      predecessor_id TEXT,
      FOREIGN KEY (task_id) REFERENCES agent_tasks(id),
      FOREIGN KEY (conversation_id) REFERENCES conversation_documents(id),
      FOREIGN KEY (predecessor_id) REFERENCES agent_tasks(id)
    )
    """
  static let conversationTasksIndexSQL = """
    CREATE INDEX conversation_tasks_parent_idx ON conversation_tasks (conversation_id)
    """
  static let conversationTimelineSQL = """
    CREATE TABLE conversation_timeline (
      sequence INTEGER PRIMARY KEY,
      conversation_id TEXT NOT NULL,
      entry_id TEXT NOT NULL,
      payload BLOB NOT NULL,
      UNIQUE (conversation_id, entry_id),
      FOREIGN KEY (conversation_id) REFERENCES conversation_documents(id) ON DELETE CASCADE
    )
    """
  static let conversationTimelineIndexSQL = """
    CREATE INDEX conversation_timeline_page_idx ON conversation_timeline (conversation_id, sequence DESC)
    """

  static func createVersionSix(connection: SQLiteConnection) throws {
    for sql in [
      conversationTasksSQL, conversationTasksIndexSQL,
      conversationTimelineSQL, conversationTimelineIndexSQL,
    ] { try connection.execute(sql) }
    let tasks = try connection.prepare("SELECT payload FROM agent_tasks ORDER BY rowid")
    while try tasks.step() == .row {
      try Task.checkCancellation()
      let task = try JSONDecoder().decode(
        AgentTaskRecord.self,
        from: tasks.columnBlob(at: 0, maximumBytes: 6 * 1_024 * 1_024))
      // No historic parent identity was saved. Preserve each standalone task as its own chat.
      try SQLiteConversationTimeline.ensureDocument(
        id: task.id, title: task.title,
        createdAt: task.createdAt, connection: connection)
      let link = try connection.prepare(
        "INSERT INTO conversation_tasks (task_id, conversation_id) VALUES (?, ?)")
      try link.bind(task.id.uuidString, at: 1)
      try link.bind(task.id.uuidString, at: 2)
      _ = try link.step()
      if task.attemptCount == 0,
        let document = try JSONSerialization.jsonObject(with: task.request) as? [String: Any],
        let messages = document["initialMessages"] as? [Any], let last = messages.last
      {
        let message = try JSONDecoder().decode(
          Message.self, from: JSONSerialization.data(withJSONObject: last))
        try SQLiteConversationTimeline.insert(
          .init(
            id: message.id.rawValue, taskID: task.id,
            timestamp: task.createdAt, content: .message(message)), conversationID: task.id,
          connection: connection)
      }
      let events = try connection.prepare(
        """
        SELECT event_id, timestamp_us, payload FROM agent_task_attempts AS attempt
        JOIN event_records AS event ON event.run_id = attempt.run_id
        WHERE attempt.task_id = ? ORDER BY attempt.attempt, event.sequence
        """)
      try events.bind(task.id.uuidString, at: 1)
      while try events.step() == .row {
        try Task.checkCancellation()
        guard let id = UUID(uuidString: try events.columnText(at: 0, maximumBytes: 36)) else {
          throw AgentTaskStorageError.invalidRecord
        }
        let event = try JSONDecoder().decode(
          AgentEvent.self,
          from: events.columnBlob(at: 2, maximumBytes: 3 * 1_024 * 1_024))
        let date = Date(timeIntervalSince1970: Double(try events.columnInt64(at: 1)) / 1_000_000)
        if let entry = SQLiteConversationTimeline.project(
          event, eventID: id, taskID: task.id,
          timestamp: date, includeMessages: true)
        {
          try SQLiteConversationTimeline.insert(
            entry, conversationID: task.id, connection: connection)
        }
      }
    }
    try connection.execute("PRAGMA user_version = 6")
  }

  static var conversationTaskSchemaObjects: [String] {
    [
      schemaObjectKey(
        type: "table", name: "conversation_tasks", table: "conversation_tasks",
        sql: conversationTasksSQL),
      schemaObjectKey(
        type: "index", name: "sqlite_autoindex_conversation_tasks_1", table: "conversation_tasks",
        sql: nil),
      schemaObjectKey(
        type: "index", name: "conversation_tasks_parent_idx", table: "conversation_tasks",
        sql: conversationTasksIndexSQL),
      schemaObjectKey(
        type: "table", name: "conversation_timeline", table: "conversation_timeline",
        sql: conversationTimelineSQL),
      schemaObjectKey(
        type: "index", name: "sqlite_autoindex_conversation_timeline_1",
        table: "conversation_timeline", sql: nil),
      schemaObjectKey(
        type: "index", name: "conversation_timeline_page_idx", table: "conversation_timeline",
        sql: conversationTimelineIndexSQL),
    ]
  }
}
