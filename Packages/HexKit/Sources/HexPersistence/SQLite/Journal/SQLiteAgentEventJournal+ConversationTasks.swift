import Foundation
import HexCore

extension SQLiteAgentEventJournal {
  public func activeConversationTask(_ id: UUID) throws -> AgentTaskRecord? {
    let connection = try requireConnection()
    let sql = try connection.prepare(
      """
      SELECT task.id FROM conversation_tasks AS link JOIN agent_tasks AS task ON task.id = link.task_id
      WHERE link.conversation_id = ? AND task.phase NOT IN ('completed', 'cancelled')
      ORDER BY task.rowid ASC LIMIT 1
      """)
    try sql.bind(id.uuidString, at: 1)
    guard try sql.step() == .row,
      let taskID = UUID(uuidString: try sql.columnText(at: 0, maximumBytes: 36))
    else { return nil }
    return try taskRecord(taskID, connection: connection)?.summary
  }

  public func conversationTasks(_ id: UUID, before: UUID?, limit: Int) throws -> [AgentTaskRecord] {
    guard (1...20).contains(limit) else { throw AgentTaskStorageError.invalidRecord }
    let connection = try requireConnection()
    let sql = try connection.prepare(
      """
      SELECT task.id FROM conversation_tasks AS link JOIN agent_tasks AS task ON task.id = link.task_id
      WHERE link.conversation_id = ? AND (? = '' OR task.rowid < (SELECT rowid FROM agent_tasks WHERE id = ?))
      ORDER BY task.rowid DESC LIMIT ?
      """)
    try sql.bind(id.uuidString, at: 1)
    try sql.bind(before?.uuidString ?? "", at: 2)
    try sql.bind(before?.uuidString ?? "", at: 3)
    try sql.bind(Int64(limit), at: 4)
    var records: [AgentTaskRecord] = []
    while try sql.step() == .row {
      guard let taskID = UUID(uuidString: try sql.columnText(at: 0, maximumBytes: 36)),
        let record = try taskRecord(taskID, connection: connection)
      else { throw AgentTaskStorageError.invalidRecord }
      records.append(record.summary)
    }
    return records
  }

  func hydrateConversationLink(_ record: inout AgentTaskRecord, connection: SQLiteConnection) throws
  {
    let sql = try connection.prepare(
      "SELECT conversation_id, predecessor_id FROM conversation_tasks WHERE task_id = ?")
    try sql.bind(record.id.uuidString, at: 1)
    guard try sql.step() == .row,
      let parent = UUID(uuidString: try sql.columnText(at: 0, maximumBytes: 36))
    else {
      throw AgentTaskStorageError.invalidRecord
    }
    let predecessor = try sql.columnOptionalText(at: 1, maximumBytes: 36).flatMap(UUID.init)
    guard record.conversationID == nil || record.conversationID == parent,
      record.predecessorID == predecessor
    else { throw AgentTaskStorageError.invalidRecord }
    record.conversationID = parent
  }

  func validateConversationTaskAdmission(_ record: AgentTaskRecord, connection: SQLiteConnection)
    throws
  {
    guard let parent = record.conversationID else { throw AgentTaskStorageError.invalidRecord }
    let latest = try connection.prepare(
      """
      SELECT task_id FROM conversation_tasks WHERE conversation_id = ? ORDER BY rowid DESC LIMIT 1
      """)
    try latest.bind(parent.uuidString, at: 1)
    let previous =
      try latest.step() == .row
      ? UUID(uuidString: try latest.columnText(at: 0, maximumBytes: 36)) : nil
    guard previous == record.predecessorID else { throw AgentTaskStorageError.revisionConflict }
    if let document = try conversationDocument(parent, connection: connection),
      document.archivedAt != nil
    {
      throw AgentTaskStorageError.invalidRecord
    }
  }

  func saveConversationTaskLink(
    _ record: AgentTaskRecord, previous: AgentTaskRecord?,
    connection: SQLiteConnection
  ) throws {
    guard let parent = record.conversationID else { throw AgentTaskStorageError.invalidRecord }
    if previous == nil {
      try SQLiteConversationTimeline.ensureDocument(
        id: parent, title: record.title,
        createdAt: record.createdAt, connection: connection)
      let sql = try connection.prepare(
        "INSERT INTO conversation_tasks (task_id, conversation_id, predecessor_id) VALUES (?, ?, ?)"
      )
      try sql.bind(record.id.uuidString, at: 1)
      try sql.bind(parent.uuidString, at: 2)
      if let id = record.predecessorID {
        try sql.bind(id.uuidString, at: 3)
      } else {
        try sql.bindNull(at: 3)
      }
      _ = try sql.step()
      if let runID = record.runID {
        let events = try connection.prepare(
          "SELECT payload FROM event_records WHERE run_id = ? ORDER BY sequence")
        try events.bind(runID.rawValue.uuidString, at: 1)
        while try events.step() == .row {
          let event = try JSONDecoder().decode(
            AgentEvent.self,
            from: events.columnBlob(at: 0, maximumBytes: configuration.maximumPayloadBytes))
          try recordTaskEffect(event, runID: runID, connection: connection)
        }
      }
      if let message = record.userMessage {
        try SQLiteConversationTimeline.insert(
          .init(
            id: message.id.rawValue, taskID: record.id,
            timestamp: record.createdAt, content: .message(message)), conversationID: parent,
          connection: connection)
      }
    }
    for instruction in record.instructions
    where !(previous?.instructions.contains(where: { $0.id == instruction.id }) ?? false) {
      let message = Message(
        id: MessageID(rawValue: instruction.id), role: .user, content: [.text(instruction.text)])
      try SQLiteConversationTimeline.insert(
        .init(
          id: instruction.id, taskID: record.id,
          timestamp: record.updatedAt, content: .message(message)), conversationID: parent,
        connection: connection)
    }
    if let text = record.reconciliation, text != previous?.reconciliation,
      let id = record.lastControlID
    {
      let message = Message(id: MessageID(rawValue: id), role: .user, content: [.text(text)])
      try SQLiteConversationTimeline.insert(
        .init(
          id: id, taskID: record.id,
          timestamp: record.updatedAt, content: .message(message)), conversationID: parent,
        connection: connection)
    }
    let touch = try connection.prepare(
      "UPDATE conversation_documents SET updated_at_us = ?, revision = revision + 1 WHERE id = ?")
    try touch.bind(AgentEventCodec.microseconds(for: record.updatedAt), at: 1)
    try touch.bind(parent.uuidString, at: 2)
    _ = try touch.step()
  }
}
