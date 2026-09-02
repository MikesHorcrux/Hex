/// The inference backends that Hex can select in its settings surface.
///
/// The Codex case is deliberately named as a compatibility mode. A ChatGPT subscription is not
/// an OpenAI Platform API key and this mode must never be presented as raw API inference.
public enum HexInferenceBackendKind: String, Codable, CaseIterable, Hashable, Identifiable, Sendable
{
  case openAIResponses = "openai-responses"
  case mlxLocal = "mlx-local"
  case codexCompatibility = "codex-compatibility"

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .openAIResponses:
      "OpenAI Responses API"
    case .mlxLocal:
      "Local MLX"
    case .codexCompatibility:
      "Codex compatibility"
    }
  }

  public var detail: String {
    switch self {
    case .openAIResponses:
      "OpenAI Platform API-key inference"
    case .mlxLocal:
      "Run an existing model directory on this Mac"
    case .codexCompatibility:
      "Use the Codex app-server account/runtime"
    }
  }
}
