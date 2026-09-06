import Foundation

/// Searches immutable, user-visible conversation snapshots away from the main actor.
/// Native provider history and output files are deliberately outside this boundary.
actor AgentConversationSearch {
  func matchingConversationIDs(
    in conversations: [AgentConversation], query: String
  ) throws -> Set<UUID> {
    try Task.checkCancellation()
    let normalizedQuery = AgentConversationSearchRequest.normalizedQuery(query)
    var matches: Set<UUID> = []

    for conversation in conversations {
      try Task.checkCancellation()
      if normalizedQuery.isEmpty || contains(normalizedQuery, in: conversation.title) {
        matches.insert(conversation.id)
        continue
      }
      for row in conversation.transcript {
        try Task.checkCancellation()
        if contains(normalizedQuery, in: row.text) {
          matches.insert(conversation.id)
          break
        }
      }
    }

    try Task.checkCancellation()
    return matches
  }

  private func contains(_ query: String, in text: String) -> Bool {
    let normalizedText = AgentConversationSearchRequest.normalizedQuery(text)
    return normalizedText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
      != nil
  }
}
