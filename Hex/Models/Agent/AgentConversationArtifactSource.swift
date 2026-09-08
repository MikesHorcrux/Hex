import HexCore

/// Source identity for an output whose original tool-call message is retained in SQLite. Keeping
/// this compact provenance lets a context checkpoint release the call's potentially large arguments.
nonisolated struct AgentConversationArtifactSource: Codable, Equatable, Sendable {
  let runID: AgentRunID
  let toolCallID: ToolCallID
  let messageID: MessageID
}
