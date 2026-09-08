import Foundation

/// The two OpenAI-hosted routes supported by Hex's own Responses client.
public enum OpenAIResponsesService: String, Codable, Equatable, Sendable {
  case platformAPI = "platform-api"
  case chatGPTCodexSubscription = "chatgpt-codex-subscription"

  var endpoint: URL? {
    switch self {
    case .platformAPI:
      URL(string: "https://api.openai.com/v1/responses")
    case .chatGPTCodexSubscription:
      URL(string: "https://chatgpt.com/backend-api/codex/responses")
    }
  }

  public var defaultPrivacyMode: OpenAIResponsesPrivacyMode {
    switch self {
    case .platformAPI:
      .serverManagedContinuation
    case .chatGPTCodexSubscription:
      .localEphemeralReplay
    }
  }

  public var displayName: String {
    switch self {
    case .platformAPI:
      "OpenAI API"
    case .chatGPTCodexSubscription:
      "OpenAI via ChatGPT / Codex"
    }
  }
}
