import HexCore

nonisolated struct AgentConversationContextProjectionSnapshot {
  var messages: [Message]
  var boundaries: Set<Int>
  var unresolvedIDs: Set<MessageID> = []

  nonisolated init(legacyMessages: [Message]) {
    messages = legacyMessages
    boundaries = []
    for (index, _) in legacyMessages.enumerated() {
      let end = index + 1
      if end == legacyMessages.count || legacyMessages[end].role == .user {
        boundaries.insert(end)
      }
    }
  }

  nonisolated mutating func apply(_ compaction: AgentContextCompaction) throws {
    let count = compaction.sourceMessageIDs.count
    guard count <= messages.count, boundaries.contains(count),
      Array(messages.prefix(count).map(\.id)) == compaction.sourceMessageIDs,
      unresolvedIDs.isDisjoint(with: compaction.sourceMessageIDs)
    else {
      throw AgentConversationStoreError.invalidArchive(
        "A compaction does not cover an exact, closed historical context prefix.")
    }
    messages = [compaction.summaryMessage] + messages.dropFirst(count)
    boundaries = Set(boundaries.filter { $0 > count }.map { $0 - count + 1 })
    boundaries.insert(1)
  }

  nonisolated mutating func append(_ exchange: AgentConversationExchange) {
    messages.append(contentsOf: exchange.messages)
    boundaries.insert(messages.count)
    var pending = Set<ToolCallID>()
    for content in exchange.messages.flatMap(\.content) {
      switch content {
      case .toolCall(let call): pending.insert(call.id)
      case .toolResult(let result): pending.remove(result.toolCallID)
      case .text, .image: break
      }
    }
    if exchange.outcome == .inProgress || exchange.outcome == .interrupted || !pending.isEmpty {
      unresolvedIDs.formUnion(exchange.messages.map(\.id))
    }
  }
}
