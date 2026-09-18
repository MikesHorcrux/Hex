import Foundation
import HexCore
import HexPersistence
import HexProviders

nonisolated enum HexInProcessInferenceResolutionError: Error, Equatable, LocalizedError,
  Sendable
{
  case settingsUnavailable
  case credentialsUnavailable(HexOpenAIAuthenticationMethod)
  case unsupportedBackend(HexInferenceBackendKind)

  var errorDescription: String? {
    switch self {
    case .settingsUnavailable:
      "Hex could not load inference-backend settings. Open Inference settings and choose a supported configuration."
    case .credentialsUnavailable(.apiKey):
      "OpenAI is selected, but no API key is available in Keychain. Add one in Inference settings."
    case .credentialsUnavailable(.chatGPT):
      "OpenAI is selected, but Hex is not signed in with ChatGPT. Sign in under Inference settings."
    case .unsupportedBackend(.mlxLocal):
      "Local MLX is selected, but its in-process inference adapter is not linked in this build. Link and configure the MLX adapter before selecting it."
    case .unsupportedBackend(.llamaCppLocal):
      "Local GGUF is selected, but the in-process llama.cpp adapter is unavailable. Use the resident Hex Agent with Prism llama-server."
    case .unsupportedBackend(.openAIResponses):
      "OpenAI is selected, but its in-process inference adapter is unavailable. Check the Hex build configuration."
    }
  }
}
