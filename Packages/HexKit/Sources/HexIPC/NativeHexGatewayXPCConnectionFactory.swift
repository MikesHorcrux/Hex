import Foundation

/// Production factory for local user-session Mach-service connections. Constructing this value is
/// inert; the service name is contacted only when `makeConnection()` is called by a handshake.
public struct NativeHexGatewayXPCConnectionFactory: HexGatewayXPCConnectionFactory, Sendable {
  public let machServiceName: String
  public let configuration: GatewayConfiguration

  public init(
    machServiceName: String,
    configuration: GatewayConfiguration = .standard
  ) {
    self.machServiceName = machServiceName
    self.configuration = configuration
  }

  public func makeConnection() -> any HexGatewayXPCConnection {
    NativeHexGatewayXPCConnection(
      machServiceName: machServiceName,
      configuration: configuration
    )
  }
}
