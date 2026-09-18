import Foundation

/// Secret-free validation failures for persisted inference-backend settings.
public enum HexInferenceBackendSettingsError: Error, Equatable, LocalizedError, Sendable {
  case unsupportedSchemaVersion(Int)
  case invalidOpenAIModelID
  case invalidMLXModelID
  case invalidMLXDisplayName
  case invalidMLXDirectory
  case invalidMLXOutputTokens
  case invalidMLXContextWindow
  case invalidLlamaModelID
  case invalidLlamaDisplayName
  case invalidLlamaEndpoint
  case invalidLlamaOutputTokens
  case invalidLlamaContextWindow

  public var errorDescription: String? {
    switch self {
    case .unsupportedSchemaVersion:
      "The inference-backend settings use an unsupported schema version."
    case .invalidOpenAIModelID:
      "The OpenAI model identifier is invalid."
    case .invalidMLXModelID:
      "The MLX model identifier is invalid."
    case .invalidMLXDisplayName:
      "The MLX model display name is invalid."
    case .invalidMLXDirectory:
      "The MLX model directory is invalid."
    case .invalidMLXOutputTokens:
      "The MLX output-token limit is invalid."
    case .invalidMLXContextWindow:
      "The MLX context window is invalid."
    case .invalidLlamaModelID:
      "The llama.cpp model identifier is invalid."
    case .invalidLlamaDisplayName:
      "The llama.cpp model display name is invalid."
    case .invalidLlamaEndpoint:
      "The llama.cpp server endpoint is invalid."
    case .invalidLlamaOutputTokens:
      "The llama.cpp output-token limit is invalid."
    case .invalidLlamaContextWindow:
      "The llama.cpp context window is invalid."
    }
  }
}
