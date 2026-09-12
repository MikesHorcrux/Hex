import HexCore

/// Provider-neutral durable history. Legacy messages are explicitly text-only projections, not
/// recovered native tool records; exchanges retain the committed messages of each new attempt.
nonisolated struct AgentConversationHistory: Codable, Equatable, Sendable {
  /// Validated inference projection whose originals and summary provenance are already in SQLite.
  /// This is never populated by the legacy JSON reader or inferred from rendered transcript text.
  var contextBase: [Message]?
  var legacyMessages: [Message]
  var exchanges: [AgentConversationExchange]
  var compactions: [AgentContextCompaction]

  init(
    legacyMessages: [Message] = [], exchanges: [AgentConversationExchange] = [],
    compactions: [AgentContextCompaction] = [], contextBase: [Message]? = nil
  ) {
    self.contextBase = contextBase
    self.legacyMessages = legacyMessages
    self.exchanges = exchanges
    self.compactions = compactions
  }

  private enum CodingKeys: String, CodingKey {
    case legacyMessages, exchanges, compactions, contextBase
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    contextBase = try container.decodeIfPresent([Message].self, forKey: .contextBase)
    legacyMessages = try container.decode([Message].self, forKey: .legacyMessages)
    exchanges = try container.decode([AgentConversationExchange].self, forKey: .exchanges)
    compactions =
      try container.decodeIfPresent([AgentContextCompaction].self, forKey: .compactions) ?? []
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(contextBase, forKey: .contextBase)
    try container.encode(legacyMessages, forKey: .legacyMessages)
    try container.encode(exchanges, forKey: .exchanges)
    // Keep canonical v2 bytes unchanged when no compaction has occurred. Loading never rewrites.
    if !compactions.isEmpty {
      try container.encode(compactions, forKey: .compactions)
    }
  }
}
