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
    case .backendNotConfigured(.codexCompatibility):
      "Codex compatibility is selected, but no Codex executable is configured. Choose an existing Codex app-server executable in Inference settings."
    case .backendNotConfigured(.openAIResponses):
      "OpenAI Responses is selected, but its model configuration is incomplete. Choose an OpenAI model in Inference settings."
    case .providerUnavailable(.mlxLocal):
      "Local MLX is selected, but no MLX inference adapter is linked in this build. Link and configure the MLX provider before selecting Local MLX."
    case .providerUnavailable(.codexCompatibility):
      "Codex compatibility is selected, but no app-server runtime adapter is configured in this build. Configure a Codex compatibility adapter before selecting it; a ChatGPT subscription is never used as raw inference."
    case .providerUnavailable(.openAIResponses):
      "OpenAI Responses is selected, but its inference provider is unavailable. Check the resident gateway build configuration."
    case .providerInitializationFailed(.mlxLocal):
      "The selected MLX inference adapter could not be initialized. Check the existing model directory and adapter configuration."
    case .providerInitializationFailed(.codexCompatibility):
      "The selected Codex compatibility adapter could not be initialized. Check the existing executable and app-server configuration."
    case .providerInitializationFailed(.openAIResponses):
      "The selected OpenAI Responses provider could not be initialized. Check the saved model configuration."
    }
  }
}
