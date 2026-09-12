import Foundation

public enum ConversationTimelineEntryContent: Codable, Equatable, Sendable {
  case message(Message)
  /// Provider-supplied progress summaries and journaled run outcomes, never private reasoning.
  case notice(String)
  case toolStarted(String)
  case toolFinished(ToolResult)
}
