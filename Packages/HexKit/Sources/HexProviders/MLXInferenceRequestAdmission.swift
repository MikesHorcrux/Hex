import HexCore

/// Shared admission for provider-owned and directly exposed MLX engine requests.
public enum MLXInferenceRequestAdmission: Sendable {
  public static func validate(
    _ request: InferenceRequest,
    modelID: ModelID,
    maximumOutputTokens: Int,
    maximumContextTokens: Int,
    supportsToolCalling: Bool
  ) throws {
    guard
      !request.providerID.rawValue.isEmpty,
      request.providerID.rawValue.utf8.count <= 256,
      !request.providerID.rawValue.contains("\0"),
      request.modelID == modelID
    else {
      throw MLXLocalInferenceProviderError.invalidRequest
    }
    guard request.previousProviderResponseID == nil else {
      throw MLXLocalInferenceProviderError.unsupportedContinuation
    }
    guard
      maximumOutputTokens > 0,
      maximumContextTokens > 0,
      maximumOutputTokens <= maximumContextTokens,
      request.options.maxOutputTokens.map({
        $0 > 0 && $0 <= maximumOutputTokens
      }) ?? true,
      request.options.temperature.map({
        $0.isFinite && (0...2).contains($0)
      }) ?? true,
      MLXRequestContentValidator.validate(request)
    else {
      throw MLXLocalInferenceProviderError.invalidRequest
    }
    if !request.tools.isEmpty, !supportsToolCalling {
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
  }
}
