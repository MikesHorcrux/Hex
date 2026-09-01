import HexCore

/// A fail-closed fallback for headless or incompletely composed runtimes.
public struct DenyingAuthorizationPrompter: AuthorizationPrompting, Sendable {
  public init() {}

  public func requestDecision(
    for request: AuthorizationRequest
  ) async throws -> AuthorizationPromptResponse {
    .deny(reason: "No interactive authorization prompt is available.")
  }
}
