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
    guard
      !request.messages.isEmpty,
      request.messages.count <= 4_096,
      request.tools.count <= 4_096,
      request.options.maxOutputTokens.map({
        (1...model.maximumOutputTokens).contains($0)
      }) ?? true,
      request.options.temperature.map({
        $0.isFinite && (0...2).contains($0)
      }) ?? true,
      MLXRequestContentValidator.validate(request)
    else {
      throw MLXLocalInferenceProviderError.invalidRequest
    }
    if !request.tools.isEmpty, !model.supportsToolCalling {
      throw MLXLocalInferenceProviderError.invalidToolChoice
    }
    switch request.toolChoice {
    case .automatic, .none:
      break
    case .required:
      guard !request.tools.isEmpty else {
        throw MLXLocalInferenceProviderError.invalidToolChoice
      }
    case .named(let name):
      guard request.tools.contains(where: { $0.name == name }) else {
        throw MLXLocalInferenceProviderError.invalidToolChoice
      }
    }
    return model
  }

  static func isValidGeneratedToolCall(
    _ call: ToolCall,
    request: InferenceRequest
  ) -> Bool {
    guard
      !call.id.rawValue.isEmpty,
      call.id.rawValue.utf8.count <= 256,
      !call.id.rawValue.contains("\0"),
      request.tools.contains(where: { $0.name == call.name }),
      let arguments = try? JSONEncoder().encode(call.arguments),
      arguments.count <= 2 * 1_024 * 1_024
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

}
