import Foundation

public struct ConversationTimelinePage: Sendable {
  public let entries: [ConversationTimelineEntry]
  public let before: Int64?
  public init(entries: [ConversationTimelineEntry], before: Int64?) {
    self.entries = entries
    self.before = before
  }
}
