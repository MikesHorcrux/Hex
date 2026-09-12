import HexCore

extension AgentConversationHistory {
  /// Reconstruct the original UI request, excluding the owning run's generated messages and
  /// compaction. A fresh retry reused its ancestor's request before either attempt generated work.
  nonisolated func initialRequestMessages(for runID: AgentRunID) throws -> [Message] {
    guard var index = exchanges.firstIndex(where: { $0.runID == runID }) else {
      throw AgentConversationStoreError.invalidArchive("A pending request has no native exchange.")
    }
    let currentUser = exchanges[index].messages.first
    while let parent = exchanges[index].retryOfRunID {
      guard index > 0, exchanges[index - 1].runID == parent,
        exchanges[index - 1].messages.first == currentUser
      else {
        throw AgentConversationStoreError.invalidArchive(
          "A pending retry does not have an adjacent, identical request ancestry.")
      }
      index -= 1
    }
    guard let user = currentUser, user.role == .user else {
      throw AgentConversationStoreError.invalidArchive(
        "A pending request has no original user message.")
    }
    let previous = Array(exchanges.prefix(index))
    let previousRunIDs = Set(previous.map(\.runID))
    let priorHistory = AgentConversationHistory(
      legacyMessages: legacyMessages, exchanges: previous,
      compactions: compactions.filter { previousRunIDs.contains($0.ownerRunID) })
    return try AgentConversationContextProjection.messages(in: priorHistory) + [user]
  }
}
