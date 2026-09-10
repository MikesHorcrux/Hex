import Foundation

/// A durable display projection. Execution truth remains in the original run journal.
public struct ConversationTimelineEntry: Codable, Equatable, Sendable, Identifiable {
  public enum Content: Codable, Equatable, Sendable {
    case message(Message)
    /// Provider-supplied progress summaries and journaled run outcomes, never private reasoning.
    case notice(String)
    case toolStarted(String)
    case toolFinished(ToolResult)
  }
  public let id: UUID
  public let taskID: UUID
  public let timestamp: Date
  public let content: Content
  public var sequence: Int64 = 0

  public init(id: UUID, taskID: UUID, timestamp: Date, content: Content) {
    self.id = id
    self.taskID = taskID
    self.timestamp = timestamp
    self.content = content
  }
}
