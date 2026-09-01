import HexCore

struct GatewayTestAuthorizationProvider: AuthorizationProvider, Sendable {
  func authorize(_ request: AuthorizationRequest) async throws -> AuthorizationDecision {
    _ = request
    try Task.checkCancellation()
    return .allow
  }
}
