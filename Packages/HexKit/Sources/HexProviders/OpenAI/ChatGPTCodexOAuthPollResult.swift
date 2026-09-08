/// Result of one poll against OpenAI's device-authorization service.
public enum ChatGPTCodexOAuthPollResult: Equatable, Sendable {
  case pending
  case authorized(authorizationCode: String, codeVerifier: String)
}
