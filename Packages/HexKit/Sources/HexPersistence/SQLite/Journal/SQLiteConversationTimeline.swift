import Foundation
import HexCore

/// Shared by live journal transactions and the schema-five backfill.
enum SQLiteConversationTimeline {
  static func ensureDocument(id: UUID, title: String, createdAt: Date, connection: SQLiteConnection)
    throws
  {
    var boundedTitle = title
    while boundedTitle.utf8.count > 256 { boundedTitle.removeLast() }
    let sql = try connection.prepare(
      """
      INSERT OR IGNORE INTO conversation_documents
      (id, title, created_at_us, updated_at_us, revision, state, next_sequence, last_operation, operation_hash)
      VALUES (?, ?, ?, ?, 1, ?, 1, ?, ?)
      """)
    try sql.bind(id.uuidString, at: 1)
    try sql.bind(boundedTitle.isEmpty ? "Conversation" : boundedTitle, at: 2)
    let timestamp = try AgentEventCodec.microseconds(for: createdAt)
    try sql.bind(timestamp, at: 3)
    try sql.bind(timestamp, at: 4)
    try sql.bind(Data("{\"durableConversation\":1}".utf8), at: 5)
    try sql.bind(id.uuidString, at: 6)
    try sql.bind(Data(), at: 7)
    _ = try sql.step()
  }

  static func insert(
    _ entry: ConversationTimelineEntry, conversationID: UUID,
    connection: SQLiteConnection
  ) throws {
    let payload = try JSONEncoder().encode(entry)
    guard payload.count <= 3 * 1_024 * 1_024 else { throw AgentTaskStorageError.invalidRecord }
    let sql = try connection.prepare(
      """
      INSERT OR IGNORE INTO conversation_timeline (conversation_id, entry_id, payload)
      VALUES (?, ?, ?)
      """)
    try sql.bind(conversationID.uuidString, at: 1)
    try sql.bind(entry.id.uuidString, at: 2)
    try sql.bind(payload, at: 3)
    _ = try sql.step()
  }

  static func project(
    _ event: AgentEvent, eventID: UUID, taskID: UUID, timestamp: Date,
    includeMessages: Bool
  ) -> ConversationTimelineEntry? {
    let content: ConversationTimelineEntry.Content
    var id = eventID
    switch event {
    case .messageAppended(let message) where includeMessages:
      guard message.role == .user || message.role == .assistant,
        message.content.contains(where: {
          if case .text(let text) = $0 { return !text.isEmpty }
          return false
        })
      else { return nil }
      id = message.id.rawValue
      content = .message(message)
    case .inferenceEvent(.reasoningSummaryDelta(let text)):
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      content = .notice(text)
    case .runFailed(let failure): content = .notice("Hex stopped: " + failure.message)
    case .runCancelled: content = .notice("Work cancelled")
    case .toolStarted(let call): content = .toolStarted(call.name)
    case .toolFinished(let result): content = .toolFinished(result)
    default: return nil
    }
    return .init(id: id, taskID: taskID, timestamp: timestamp, content: content)
  }
}
