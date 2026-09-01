import HexCore

/// Optional extension to the gateway transport for interactive authorization responses. It is a
/// separate protocol so preview and in-process transports do not acquire a fake XPC requirement.
public protocol HexGatewayAuthorizationDecisionTransport: Sendable {
  func submitAuthorizationDecision(
    _ request: AuthorizationRequest,
    choice: GatewayAuthorizationDecisionChoice,
    lease: GatewayTransportConnectionLease
  ) async throws
}
