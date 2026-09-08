import HexCore

/// Adapts the app's developer-only broker to the common decision-submission seam. This is the only
/// in-process implementation; resident mode receives an injected transport instead.
actor HexInProcessAuthorizationDecisionTransport: HexAuthorizationDecisionSubmitting {
  private let broker: HexAuthorizationBroker

  init(broker: HexAuthorizationBroker) {
    self.broker = broker
  }

  func submit(
    _ request: AuthorizationRequest,
    choice: AuthorizationDecisionChoice
  ) async throws {
    try await broker.submit(request, choice: choice)
  }
}
