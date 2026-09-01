import HexCore
import HexIPC

/// Routes an app authorization choice through the existing gateway client connection. The client
/// owns the active lease and session, so this adapter cannot accidentally create a second XPC
/// connection or submit a decision against a stale session.
nonisolated struct HexGatewayAuthorizationDecisionAdapter: HexAuthorizationDecisionSubmitting {
  private let client: HexGatewayClient

  init(client: HexGatewayClient) {
    self.client = client
  }

  func submit(
    _ request: AuthorizationRequest,
    choice: AuthorizationDecisionChoice
  ) async throws {
    try await client.submitAuthorizationDecision(
      request,
      choice: Self.gatewayChoice(for: choice)
    )
  }

  static func gatewayChoice(
    for choice: AuthorizationDecisionChoice
  ) -> GatewayAuthorizationDecisionChoice {
    switch choice {
    case .allowOnce:
      .allowOnce
    case .allowForSession:
      .allowForSession
    case .deny:
      .deny
    }
  }
}
