import HexCore

/// One actual run attempt: the latest user message and subsequent committed native messages,
/// never the request's repeated prior context. The workspace model owns mutations to these values.
nonisolated struct AgentConversationExchange: Codable, Equatable, Sendable {
  let runID: AgentRunID
  var messages: [Message]
  var outcome: AgentConversationExchangeOutcome
  var lastEventSequence: UInt64?
  var originalRetryOfRunID: AgentRunID?
  var projectionSummaryID: MessageID?
  var retryOfRunID: AgentRunID?

  init(
    runID: AgentRunID,
    messages: [Message],
    outcome: AgentConversationExchangeOutcome = .inProgress,
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
