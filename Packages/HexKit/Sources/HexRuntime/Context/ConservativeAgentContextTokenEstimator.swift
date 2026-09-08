import Foundation
import HexCore

/// Deliberately pessimistic for ordinary text/code: one token per serialized UTF-8 byte plus
/// framing. This is an approximation, NOT a universal tokenizer upper bound. Model tokenization,
/// hidden provider state, and image costs may differ; the planner reserves a separate margin.
/// Image URLs are never mistaken for image payload cost and no URL/file is opened here.
public struct ConservativeAgentContextTokenEstimator: AgentContextTokenEstimating, Sendable {
  public init() {}

  public func estimateTokens(in message: Message) throws -> Int {
    for content in message.content {
      switch content {
      case .image:
        throw AgentContextPlanningError.imageCostUnavailable
      case .toolResult(let result):
        if result.content.contains(where: {
          if case .image = $0 { return true }
          return false
        }) {
          throw AgentContextPlanningError.imageCostUnavailable
        }
      case .text, .toolCall:
        break
      }
    }
    return try estimateSerializedTokens(message, framing: 16)
  }

  public func estimateTokens(in tool: ToolDefinition) throws -> Int {
    try estimateSerializedTokens(tool, framing: 8)
  }

  private func estimateSerializedTokens(_ value: some Encodable, framing: Int) throws -> Int {
    let bytes: Int
    do {
      bytes = try JSONEncoder().encode(value).count
    } catch {
      throw AgentContextPlanningError.unserializableContent
    }
    let (total, overflow) = bytes.addingReportingOverflow(framing)
    guard !overflow else { throw AgentContextPlanningError.arithmeticOverflow }
    return total
  }
}
