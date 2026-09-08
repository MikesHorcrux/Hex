/// Injectable network boundary for the ChatGPT/Codex OAuth device-code flow.
public protocol ChatGPTCodexOAuthTransport: Sendable {
  func requestDeviceAuthorization() async throws -> ChatGPTCodexDeviceAuthorizationChallenge
  func pollDeviceAuthorization(
    deviceAuthorizationID: String,
    userCode: String
  ) async throws -> ChatGPTCodexOAuthPollResult
  func exchangeAuthorizationCode(
    _ authorizationCode: String,
    codeVerifier: String
  ) async throws -> ChatGPTCodexOAuthTokenResponse
  func refresh(_ refreshToken: String) async throws -> ChatGPTCodexOAuthTokenResponse
}
