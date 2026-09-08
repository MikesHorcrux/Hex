/// Login boundary used by Hex's settings UI. It never exposes access or refresh tokens.
public protocol ChatGPTCodexOAuthManaging: Sendable {
  func accountStatus() async -> ChatGPTCodexOAuthAccountStatus
  func startDeviceAuthorization() async throws -> ChatGPTCodexDeviceAuthorizationChallenge
  func completeDeviceAuthorization(
    _ challenge: ChatGPTCodexDeviceAuthorizationChallenge
  ) async throws
  func signOut() async throws
}
