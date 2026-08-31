public struct MCPSessionInitialization: Equatable, Sendable {
  public let protocolVersion: MCPProtocolVersion
  public let serverName: String
  public let serverVersion: String

  public init(
    protocolVersion: MCPProtocolVersion,
    serverName: String,
    serverVersion: String
  ) {
    self.protocolVersion = protocolVersion
    self.serverName = serverName
    self.serverVersion = serverVersion
  }
}
