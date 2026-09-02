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
  case invalidCodexExecutable
  case invalidCodexWorkingDirectory

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
    case .invalidCodexExecutable:
      "The Codex executable path is invalid."
    case .invalidCodexWorkingDirectory:
      "The Codex working-directory path is invalid."
    }
  }
}
