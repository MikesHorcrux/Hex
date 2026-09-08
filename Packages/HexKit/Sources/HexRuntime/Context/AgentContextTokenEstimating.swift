import HexCore

/// Inject a model tokenizer or an image-aware estimator when available. Values include the
/// item's protocol framing and must be nonnegative. Estimates are planning inputs, not usage.
public protocol AgentContextTokenEstimating: Sendable {
  func estimateTokens(in message: Message) throws -> Int
  func estimateTokens(in tool: ToolDefinition) throws -> Int
}
