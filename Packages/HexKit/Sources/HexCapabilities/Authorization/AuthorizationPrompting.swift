import HexCore

/// Presents a request to the person operating Hex. Implementations must not silently widen the
/// requested capability, operation, or resource and must propagate cancellation.
public protocol AuthorizationPrompting: Sendable {
  func requestDecision(
    for request: AuthorizationRequest
  ) async throws -> AuthorizationPromptResponse
}
