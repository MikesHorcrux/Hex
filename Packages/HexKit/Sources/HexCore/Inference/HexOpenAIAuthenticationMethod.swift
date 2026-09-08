/// How Hex authenticates requests made through its OpenAI inference provider.
///
/// Both choices keep Hex's agent loop, tools, approvals, and conversation state in Hex. They only
/// change which OpenAI service authorizes the model request.
public enum HexOpenAIAuthenticationMethod: String, Codable, CaseIterable, Identifiable, Sendable {
  case chatGPT = "chatgpt"
  case apiKey = "api-key"

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .chatGPT:
      "ChatGPT / Codex subscription"
    case .apiKey:
      "OpenAI API key"
    }
  }

  public var detail: String {
    switch self {
    case .chatGPT:
      "Sign in with ChatGPT and use models included with your Codex subscription"
    case .apiKey:
      "Use metered OpenAI Platform API billing"
    }
  }
}
