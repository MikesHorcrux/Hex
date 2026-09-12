import Foundation

/// A durable display projection. Execution truth remains in the original run journal.
public struct ConversationTimelineEntry: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let taskID: UUID
  public let timestamp: Date
  public let content: ConversationTimelineEntryContent
  public var sequence: Int64 = 0

  public init(id: UUID, taskID: UUID, timestamp: Date, content: ConversationTimelineEntryContent) {
    self.id = id
    self.taskID = taskID
    self.timestamp = timestamp
    self.content = content
  }
}
