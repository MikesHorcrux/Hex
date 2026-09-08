public struct AgentContextConfiguration: Codable, Equatable, Sendable {
  public let isEnabled: Bool
  public let fallbackContextWindow: Int
  public let fallbackOutputReserveTokens: Int
  public let safetyMarginTokens: Int
  public let maximumSummaryTokens: Int
  public let maximumSummaryCalls: Int

  public init(
    isEnabled: Bool = true,
    fallbackContextWindow: Int = 32_768,
    fallbackOutputReserveTokens: Int = 4_096,
    safetyMarginTokens: Int = 1_024,
    maximumSummaryTokens: Int = 8_192,
    maximumSummaryCalls: Int = 8
  ) {
    self.isEnabled = isEnabled
    self.fallbackContextWindow = fallbackContextWindow
    self.fallbackOutputReserveTokens = fallbackOutputReserveTokens
    self.safetyMarginTokens = safetyMarginTokens
    self.maximumSummaryTokens = maximumSummaryTokens
    self.maximumSummaryCalls = maximumSummaryCalls
  }

  func validate() throws {
    guard (1...16_777_216).contains(fallbackContextWindow),
      (1...1_048_576).contains(fallbackOutputReserveTokens),
      (0...1_048_576).contains(safetyMarginTokens),
      (1...32_768).contains(maximumSummaryTokens),
      (1...32).contains(maximumSummaryCalls)
    else { throw AgentRuntimeError.invalidConfiguration("Invalid context compaction limits.") }
  }
}
