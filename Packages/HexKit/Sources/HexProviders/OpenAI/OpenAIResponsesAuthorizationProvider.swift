/// Supplies request-time authorization without giving the inference provider ownership of login.
public protocol OpenAIResponsesAuthorizationProvider: Sendable {
  func authorization() async throws -> OpenAIResponsesAuthorization
}
