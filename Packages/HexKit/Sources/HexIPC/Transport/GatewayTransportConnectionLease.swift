import Foundation

/// A client-issued ownership token for one logical transport connection generation. Transports must
/// bind every operation to the exact lease that completed its handshake. A stale disconnect must
/// never mutate or close a physical connection owned by a newer lease.
public struct GatewayTransportConnectionLease: Codable, Hashable, Sendable {
  static let unscoped = GatewayTransportConnectionLease()

  public let rawValue: UUID

  public init() {
    rawValue = UUID()
  }

  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }
}
