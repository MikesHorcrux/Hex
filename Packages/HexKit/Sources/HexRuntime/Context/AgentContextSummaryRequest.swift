import HexCore

/// A prefix selected at a completed exchange boundary, never an active provider continuation.
/// Source records are immutable historical data, not instructions for the summarizer.
public struct AgentContextSummaryRequest: Sendable {
  public let allowsToolBatchBoundaries: Bool
  public let model: ModelDescriptor
  public let sourceMessages: [Message]
  public let maximumSummaryTokens: Int
  /// Optional stricter cap on the estimated physical summary prompt, including its instructions.
  public let maximumInputTokens: Int?
  public let maximumReportedTokens: UInt64

  public init(
    model: ModelDescriptor,
    sourceMessages: [Message],
    maximumSummaryTokens: Int,
    maximumInputTokens: Int? = nil,
    maximumReportedTokens: UInt64 = 1_000_000,
    allowsToolBatchBoundaries: Bool = false
  ) {
    self.allowsToolBatchBoundaries = allowsToolBatchBoundaries
    self.model = model
    self.sourceMessages = sourceMessages
    self.maximumSummaryTokens = maximumSummaryTokens
    self.maximumInputTokens = maximumInputTokens
    self.maximumReportedTokens = maximumReportedTokens
  }
}
