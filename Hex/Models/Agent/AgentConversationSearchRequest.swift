import Foundation

/// Lightweight task identity; the owner's revision also catches content edits with equal timestamps.
/// The caller separately captures the full Sendable snapshot for the search actor.
nonisolated struct AgentConversationSearchRequest: Equatable, Sendable {
  let query: String
  let conversationIDs: [UUID]
  let updatedAt: [Date]
  let revision: UInt64

  init(query: String, conversations: [AgentConversation], revision: UInt64 = 0) {
    self.query = Self.normalizedQuery(query)
    conversationIDs = conversations.map(\.id)
    updatedAt = conversations.map(\.updatedAt)
    self.revision = revision
  }

  static func normalizedQuery(_ query: String) -> String {
    query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}
