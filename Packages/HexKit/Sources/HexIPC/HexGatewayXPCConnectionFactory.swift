import Foundation

/// Creates a fresh physical connection for each transport handshake. A fresh connection gives a
/// reconnect a new XPC object and keeps stale leases from mutating the current connection.
public protocol HexGatewayXPCConnectionFactory: Sendable {
  func makeConnection() -> any HexGatewayXPCConnection
}
