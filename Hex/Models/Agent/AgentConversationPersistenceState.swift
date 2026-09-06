import Foundation

/// Owned by the workspace model's MainActor. Full transcripts remain in the model; these snapshots
/// contain only versions that fit the archive so one oversized result cannot block every chat.
nonisolated struct AgentConversationPersistenceState {
  var restoreFailed = false
  var persistableConversations: [UUID: AgentConversation] = [:]
  var unsavedReasons: [UUID: String] = [:]
}
