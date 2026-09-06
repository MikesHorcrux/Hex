/// Deliberately excludes provider-owned error strings and historical content.
public enum AgentContextSummarizationError: Error, Equatable, Sendable {
  case invalidRequest
  case invalidHistory
  case unestimatedImage
  case inputDoesNotFit
  case callBudgetExceeded
  case reportedTokenBudgetExceeded
  case providerFailed
  case invalidStream
  case invalidSummary
}
