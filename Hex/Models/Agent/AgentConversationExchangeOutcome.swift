import HexCore

nonisolated enum AgentConversationExchangeOutcome: String, Codable, CaseIterable, Sendable {
  case inProgress
  case completed
  case cancelled
  case failed
  case interrupted

  var isTerminal: Bool { self != .inProgress }
}
