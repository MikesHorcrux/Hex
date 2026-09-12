import Foundation
import HexCore

/// Deliberately pessimistic for ordinary text/code: one token per serialized UTF-8 byte plus
/// framing. This is an approximation, NOT a universal tokenizer upper bound. Model tokenization,
/// hidden provider state, and image costs may differ; the planner reserves a separate margin.
/// Image URLs are never mistaken for image payload cost and no URL/file is opened here.
public struct ConservativeAgentContextTokenEstimator: AgentContextTokenEstimating, Sendable {
  private let imageTokenUpperBounds: [ProviderID: [ModelID: Int]]

  /// Supply only independently established upper bounds for the selected provider and model.
  /// Unknown media remains unestimated; no network fetch or guessed image dimensions are used.
  public init(imageTokenUpperBounds: [ProviderID: [ModelID: Int]] = [:]) {
    self.imageTokenUpperBounds = imageTokenUpperBounds
  }

  public func estimateTokens(in message: Message, model: ModelDescriptor) throws -> Int {
    let count = message.content.reduce(0) { count, content in
      switch content {
      case .image: return count + 1
      case .toolResult(let result):
        return count
          + result.content.filter {
            if case .image = $0 { return true }
            return false
          }.count
      case .text, .toolCall: return count
      }
    }
    guard count > 0 else { return try estimateTokens(in: message) }
    guard let allowance = imageTokenUpperBounds[model.providerID]?[model.id] else {
      throw AgentContextPlanningError.imageCostUnavailable
    }
    guard allowance > 0 else { throw AgentContextPlanningError.invalidEstimate }
    let (media, overflow) = allowance.multipliedReportingOverflow(by: count)
    let (total, additionOverflow) = try estimateSerializedTokens(
      textCostProjection(message), framing: 16
    )
    .addingReportingOverflow(media)
    guard !overflow, !additionOverflow else { throw AgentContextPlanningError.arithmeticOverflow }
    return total
  }

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

  /// Inline image bytes are decoded as media by the provider, not tokenized as Base64 prose.
  /// This projection is used only for estimation; the original messages and receipts are unchanged.
  private func textCostProjection(_ message: Message) -> Message {
    Message(
      id: message.id, role: message.role,
      content: message.content.map { content in
        switch content {
        case .image(let image): return .image(imageCostProjection(image))
        case .toolResult(let result):
          return .toolResult(
            ToolResult(
              toolCallID: result.toolCallID, status: result.status, output: result.output,
              content: result.content.map { part in
                if case .image(let image) = part { return .image(imageCostProjection(image)) }
                return part
              }, artifacts: result.artifacts, requiresUserAttention: result.requiresUserAttention,
              notExecutedReason: result.notExecutedReason, executionOutcome: result.executionOutcome
            ))
        case .text, .toolCall: return content
        }
      })
  }

  private func imageCostProjection(_ image: ImageContent) -> ImageContent {
    guard image.sourceURL.scheme == "data" else { return image }
    return ImageContent(
      sourceURL: URL(fileURLWithPath: "/encoded-image"), mediaType: image.mediaType)
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
