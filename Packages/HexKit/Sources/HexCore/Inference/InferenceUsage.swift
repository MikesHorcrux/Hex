public struct InferenceUsage: Codable, Equatable, Sendable {
  public let inputTokens: UInt64
  public let outputTokens: UInt64
  public let cachedInputTokens: UInt64
  public let reasoningTokens: UInt64

  public init(
    inputTokens: UInt64,
    outputTokens: UInt64,
    cachedInputTokens: UInt64 = 0,
    reasoningTokens: UInt64 = 0
  ) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cachedInputTokens = cachedInputTokens
    self.reasoningTokens = reasoningTokens
  }
}
