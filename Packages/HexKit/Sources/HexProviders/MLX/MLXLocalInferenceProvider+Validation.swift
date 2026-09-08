import Foundation
import HexCore

extension MLXLocalInferenceProvider {
  func validatedModel(
    for request: InferenceRequest
  ) throws -> MLXLocalModelConfiguration {
    guard request.providerID == configuration.providerID else {
      throw MLXLocalInferenceProviderError.wrongProvider
    }
    guard request.previousProviderResponseID == nil else {
      throw MLXLocalInferenceProviderError.unsupportedContinuation
    }
    guard let model = configuration.models.first(where: { $0.modelID == request.modelID }) else {
      throw MLXLocalInferenceProviderError.unknownModel
    }
    try MLXInferenceRequestAdmission.validate(
      request,
      modelID: model.modelID,
      maximumOutputTokens: model.maximumOutputTokens,
      maximumContextTokens:
        model.contextWindow ?? model.resourcePolicy.maximumContextTokens,
      supportsToolCalling: model.supportsToolCalling
    )
    return model
  }

  static func isValidGeneratedToolCall(
    _ call: ToolCall,
    request: InferenceRequest,
    remainingBytes: inout Int,
    remainingNodes: inout Int
  ) -> Bool {
    guard
      MLXRequestContentValidator.isValidToolCallID(call.id),
      MLXRequestContentValidator.isValidToolName(call.name),
      let definition = request.tools.first(where: { $0.name == call.name }),
      MLXRequestContentValidator.consumeString(
        call.id.rawValue,
        remainingBytes: &remainingBytes
      ),
      MLXRequestContentValidator.consumeString(
        call.name,
        remainingBytes: &remainingBytes
      ),
      MLXRequestContentValidator.validateJSONObject(
        call.arguments,
        maximumBytes: 2 * 1_024 * 1_024,
        remainingBytes: &remainingBytes,
        remainingNodes: &remainingNodes
      ),
      let arguments = try? JSONEncoder().encode(call.arguments),
      arguments.count <= 2 * 1_024 * 1_024,
      MLXToolInputSchemaValidator.arguments(
        call.arguments,
        conformTo: definition.inputSchema
      )
    else {
      return false
    }
    switch request.toolChoice {
    case .automatic, .required:
      return true
    case .none:
      return false
    case .named(let name):
      return call.name == name
    }
  }

  static func validatedStopReason(
    _ stopReason: InferenceStopReason,
    textBytes: Int,
    toolCallCount: Int
  ) -> InferenceStopReason? {
    guard textBytes > 0 || toolCallCount > 0 else {
      return nil
    }
    if toolCallCount > 0 {
      switch stopReason {
      case .stop, .toolCalls:
        return .toolCalls
      case .length, .contentFilter, .other:
        return nil
      }
    }
    switch stopReason {
    case .toolCalls:
      return nil
    case .other(let value):
      guard
        !value.isEmpty,
        value.utf8.count <= 256,
        !value.contains("\0")
      else {
        return nil
      }
      return stopReason
    case .stop, .length, .contentFilter:
      return stopReason
    }
  }

  static func isValidUsage(
    _ usage: InferenceUsage,
    request: InferenceRequest,
    model: MLXLocalModelConfiguration,
    hasGeneratedOutput: Bool
  ) -> Bool {
    let maximumOutputTokens = request.options.maxOutputTokens ?? model.maximumOutputTokens
    guard
      usage.inputTokens > 0,
      usage.cachedInputTokens <= usage.inputTokens,
      usage.reasoningTokens <= usage.outputTokens,
      usage.outputTokens <= UInt64(maximumOutputTokens),
      !hasGeneratedOutput || usage.outputTokens > 0
    else {
      return false
    }
    let contextWindow = model.contextWindow ?? model.resourcePolicy.maximumContextTokens
    let (totalTokens, overflowed) = usage.inputTokens.addingReportingOverflow(
      usage.outputTokens
    )
    return !overflowed && totalTokens <= UInt64(contextWindow)
  }

}
