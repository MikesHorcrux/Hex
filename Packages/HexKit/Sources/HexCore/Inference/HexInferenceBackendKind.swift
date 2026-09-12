/// The model engines Hex can select while retaining ownership of its agent runtime.
public enum HexInferenceBackendKind:
  String, Codable, CaseIterable, Hashable, Identifiable, Sendable
{
  case openAIResponses = "openai-responses"
  case mlxLocal = "mlx-local"

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .openAIResponses:
      "OpenAI"
    case .mlxLocal:
      "Local MLX"
    }
  }

  public var detail: String {
    switch self {
    case .openAIResponses:
      "ChatGPT/Codex subscription or OpenAI API key"
    case .mlxLocal:
      "Run an existing model directory on this Mac"
    }
  }
}
