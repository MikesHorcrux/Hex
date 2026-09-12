/// Estimated input costs plus explicitly reserved output and safety margin. These values do not
/// claim provider-reported usage, hidden-reasoning size, or a guarantee against context overflow.
public struct AgentContextBudget: Equatable, Sendable {
  public let contextWindowTokens: Int
  public let usesFallbackContextWindow: Bool
  public let pinnedTokens: Int
  public let historyTokens: Int
  public let protectedHistoryTokens: Int
  public let toolSchemaTokens: Int
  public let outputReserveTokens: Int
  public let safetyMarginTokens: Int
  public let estimatedTotalTokens: Int
  public let estimatedProtectedTotalTokens: Int

}
