import HexCore

/// One actual run attempt: the latest user message and subsequent committed native messages,
/// never the request's repeated prior context. The workspace model owns mutations to these values.
nonisolated struct AgentConversationExchange: Codable, Equatable, Sendable {
  nonisolated enum Outcome: String, Codable, CaseIterable, Sendable {
    case inProgress
    case completed
    case cancelled
    case failed
    case interrupted

    var isTerminal: Bool { self != .inProgress }
  }

  let runID: AgentRunID
  var messages: [Message]
  var outcome: Outcome
  var lastEventSequence: UInt64?
  var originalRetryOfRunID: AgentRunID?
  var projectionSummaryID: MessageID?
  var retryOfRunID: AgentRunID?

  init(
    runID: AgentRunID,
    messages: [Message],
    outcome: Outcome = .inProgress,
    lastEventSequence: UInt64? = nil,
    retryOfRunID: AgentRunID? = nil
  ) {
    self.runID = runID
    self.messages = messages
    self.outcome = outcome
    self.lastEventSequence = lastEventSequence
    self.retryOfRunID = retryOfRunID
  }
}
