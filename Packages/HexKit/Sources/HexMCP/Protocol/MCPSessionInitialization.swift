public struct MCPSessionInitialization: Equatable, Sendable {
  public let protocolVersion: MCPProtocolVersion
  public let serverName: String
  public let serverVersion: String
  public let supportsTaskAugmentedToolCalls: Bool

  public init(
    protocolVersion: MCPProtocolVersion,
    serverName: String,
    serverVersion: String,
    supportsTaskAugmentedToolCalls: Bool = false
  ) {
    self.protocolVersion = protocolVersion
    self.serverName = serverName
    self.serverVersion = serverVersion
    self.supportsTaskAugmentedToolCalls = supportsTaskAugmentedToolCalls
  }
}
