import Foundation
import HexCore

/// Redacted, actionable failures raised when the resident gateway resolves a selected backend.
public enum HexGatewayInferenceProviderFactoryError: Error, Equatable, LocalizedError, Sendable {
  case backendNotConfigured(HexInferenceBackendKind)
  case providerUnavailable(HexInferenceBackendKind)
  case providerInitializationFailed(HexInferenceBackendKind)

  public var errorDescription: String? {
    switch self {
    case .backendNotConfigured(.mlxLocal):
      "Local MLX is selected, but no model directory is configured. Choose an existing MLX model directory in Inference settings."
    case .backendNotConfigured(.openAIResponses):
      "OpenAI is selected, but its model configuration is incomplete. Choose an OpenAI model in Inference settings."
    case .backendNotConfigured(.llamaCppLocal):
      "Local GGUF is selected, but no llama.cpp model or server endpoint is configured. Configure the local GGUF backend in Inference settings."
    case .providerUnavailable(.mlxLocal):
      "Local MLX is selected, but no MLX inference adapter is linked in this build. Link and configure the MLX provider before selecting Local MLX."
    case .providerUnavailable(.openAIResponses):
      "OpenAI is selected, but its inference provider is unavailable. Check the resident gateway build configuration."
    case .providerUnavailable(.llamaCppLocal):
      "Local GGUF is selected, but its llama.cpp inference adapter is unavailable. Check the resident gateway build configuration."
    case .providerInitializationFailed(.mlxLocal):
      "The selected MLX inference adapter could not be initialized. Check the existing model directory and adapter configuration."
    case .providerInitializationFailed(.openAIResponses):
      "The selected OpenAI provider could not be initialized. Check the saved model and authentication method."
    case .providerInitializationFailed(.llamaCppLocal):
      "The selected local GGUF provider could not be initialized. Start Prism llama-server and check its endpoint."
    }
  }
}
