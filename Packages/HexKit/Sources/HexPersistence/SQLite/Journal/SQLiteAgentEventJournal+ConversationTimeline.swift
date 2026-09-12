import Foundation
import HexCore

extension SQLiteAgentEventJournal {
  public func conversationTimeline(_ id: UUID, before: Int64?, limit: Int) throws
    -> ConversationTimelinePage
  {
    guard (1...50).contains(limit), before == nil || (before ?? 0) > 0 else {
      throw AgentTaskStorageError.invalidRecord
    }
    let sql = try requireConnection().prepare(
      """
      SELECT sequence, payload FROM conversation_timeline
      WHERE conversation_id = ? AND sequence < ? ORDER BY sequence DESC LIMIT ?
      """)
    try sql.bind(id.uuidString, at: 1)
    try sql.bind(before ?? Int64.max, at: 2)
    try sql.bind(Int64(limit + 1), at: 3)
    var entries: [ConversationTimelineEntry] = []
    var bytes = 0
    var hasMore = false
    while try sql.step() == .row {
      let payload = try sql.columnBlob(at: 1, maximumBytes: 3 * 1_024 * 1_024)
      if entries.count == limit || bytes + payload.count > 3 * 1_024 * 1_024 {
        hasMore = true
        break
      }
      var entry = try JSONDecoder().decode(ConversationTimelineEntry.self, from: payload)
      entry.sequence = try sql.columnInt64(at: 0)
      entries.append(entry)
      bytes += payload.count
    }
    return .init(entries: entries.reversed(), before: hasMore ? entries.last?.sequence : nil)
  }

  func recordConversationEvent(
    _ event: AgentEvent, eventID: UUID, runID: AgentRunID,
    timestamp: Date, connection: SQLiteConnection
  ) throws {
    let link = try connection.prepare(
      """
      SELECT link.conversation_id, link.task_id FROM agent_task_attempts AS attempt
      JOIN conversation_tasks AS link ON link.task_id = attempt.task_id WHERE attempt.run_id = ?
      """)
    try link.bind(runID.rawValue.uuidString, at: 1)
    guard try link.step() == .row,
      let conversationID = UUID(uuidString: try link.columnText(at: 0, maximumBytes: 36)),
      let taskID = UUID(uuidString: try link.columnText(at: 1, maximumBytes: 36))
    else { return }
    let inference = try connection.prepare(
      "SELECT 1 FROM event_records WHERE run_id = ? AND kind = 'inference_requested' LIMIT 1")
    try inference.bind(runID.rawValue.uuidString, at: 1)
    let generated = try inference.step() == .row
    if let entry = SQLiteConversationTimeline.project(
      event, eventID: eventID, taskID: taskID,
      timestamp: timestamp, includeMessages: generated)
    {
      try SQLiteConversationTimeline.insert(
        entry, conversationID: conversationID, connection: connection)
    }
  }
}
