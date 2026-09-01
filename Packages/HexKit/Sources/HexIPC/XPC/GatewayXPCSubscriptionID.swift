import Foundation

/// The client-issued identity of one physical event subscription. It is scoped by the lease and
/// session in the enclosing request, so an old connection cannot cancel a newer subscription.
public struct GatewayXPCSubscriptionID: Codable, Equatable, Hashable, Sendable {
  public let rawValue: UUID

  public init() {
    rawValue = UUID()
  }

  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }
}
