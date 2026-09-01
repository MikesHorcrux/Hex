import Foundation

/// A bounded, version-neutral request envelope used as the only request argument in the XPC
/// interface. `body` contains the operation-specific JSON produced by `GatewayWireCodec`.
public struct GatewayXPCRequestEnvelope: Codable, Equatable, Sendable {
  public let operation: GatewayXPCOperation
  public let lease: GatewayTransportConnectionLease
  public let sessionID: GatewaySessionID?
  public let subscriptionID: GatewayXPCSubscriptionID?
  public let body: Data

  public init(
    operation: GatewayXPCOperation,
    lease: GatewayTransportConnectionLease,
    sessionID: GatewaySessionID? = nil,
    subscriptionID: GatewayXPCSubscriptionID? = nil,
    body: Data
  ) {
    self.operation = operation
    self.lease = lease
    self.sessionID = sessionID
    self.subscriptionID = subscriptionID
    self.body = body
  }

  public func cancellationEnvelope() -> GatewayXPCRequestEnvelope {
    GatewayXPCRequestEnvelope(
      operation: .cancelSubscription,
      lease: lease,
      sessionID: sessionID,
      subscriptionID: subscriptionID,
      body: Data()
    )
  }
}
