import HexCore

/// Non-destructive inference projection. Native history and superseded retry metadata stay intact.
/// Validation uses the context that actually existed before each owning attempt, not today's tail.
nonisolated enum AgentConversationContextProjection {
  nonisolated static func messages(in history: AgentConversationHistory) throws -> [Message] {
    guard !history.compactions.isEmpty else { return uncompactedMessages(in: history) }
    let byOwner = try validatedCompactions(in: history)
    var projection = Snapshot(legacyMessages: history.legacyMessages)
    var previousBase: Snapshot?
    var previousRunID: AgentRunID?

    for exchange in history.exchanges {
      if let retryOfRunID = exchange.retryOfRunID {
        guard retryOfRunID == previousRunID, let previousBase else {
          throw invalid("Compacted history requires an adjacent retry ancestry.")
        }
        // A retry reuses its original initial request, not the failed attempt's generated summary.
        projection = previousBase
      }
      let initial = projection
      if let compaction = byOwner[exchange.runID] {
        try projection.apply(compaction)
      }
      projection.append(exchange)
      previousBase = initial
      previousRunID = exchange.runID
    }
    return projection.messages
  }

  nonisolated static func uncompactedMessages(in history: AgentConversationHistory) -> [Message] {
    let superseded = Set(history.exchanges.compactMap(\.retryOfRunID))
    return history.legacyMessages
      + history.exchanges.filter { !superseded.contains($0.runID) }.flatMap(\.messages)
  }

  private nonisolated static func validatedCompactions(in history: AgentConversationHistory) throws
    -> [AgentRunID: AgentContextCompaction]
  {
    guard history.compactions.count <= history.exchanges.count,
      history.compactions.count <= 512
    else { throw invalid("Conversation compaction metadata exceeds its record limits.") }
    let positions = Dictionary(
      history.exchanges.enumerated().map { ($0.element.runID, $0.offset) },
      uniquingKeysWith: { first, _ in first })
    var identities = Set(
      (history.legacyMessages + history.exchanges.flatMap(\.messages)).map(\.id))
    var byOwner: [AgentRunID: AgentContextCompaction] = [:]
    var previousPosition = -1
    for compaction in history.compactions {
      _ = try compaction.validated()
      guard let position = positions[compaction.ownerRunID], position > previousPosition,
        identities.insert(compaction.summaryMessage.id).inserted,
        byOwner.updateValue(compaction, forKey: compaction.ownerRunID) == nil
      else { throw invalid("A compaction has an unknown, duplicate, or out-of-order identity.") }
      try AgentConversationPayloadValidator.validate(compaction.summaryMessage)
      previousPosition = position
    }
    return byOwner
  }

  private nonisolated struct Snapshot {
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
        throw AgentConversationContextProjection.invalid(
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

  private nonisolated static func invalid(_ reason: String) -> AgentConversationStoreError {
    .invalidArchive(reason)
  }
}
