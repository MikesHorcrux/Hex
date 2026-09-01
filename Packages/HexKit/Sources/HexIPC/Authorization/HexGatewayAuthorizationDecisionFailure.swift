import Foundation

/// Optional error seam for authorization brokers crossing the XPC boundary. The wire codec maps
/// these errors to a bounded `GatewayFailure` without exposing provider or credential details.
public protocol HexGatewayAuthorizationDecisionFailure: Swift.Error, Sendable {
  var gatewayFailure: GatewayFailure { get }
}
