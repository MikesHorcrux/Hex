import HexCore

/// A bounded, exact authorization response payload. The full request is echoed back intentionally:
/// the resident broker compares every field, rather than trusting only the request identifier.
public struct GatewayAuthorizationDecisionRequest: Codable, Equatable, Sendable {
  public let request: AuthorizationRequest
  public let choice: GatewayAuthorizationDecisionChoice

  public init(
    request: AuthorizationRequest,
    choice: GatewayAuthorizationDecisionChoice
  ) {
    self.request = request
    self.choice = choice
  }
}
