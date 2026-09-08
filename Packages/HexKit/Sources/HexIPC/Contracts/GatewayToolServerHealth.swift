public struct GatewayToolServerHealth: Codable, Equatable, Sendable {
  public let servers: [GatewayToolServerStatus]

  public init(servers: [GatewayToolServerStatus] = []) { self.servers = servers }

  public func validated() throws -> Self {
    guard servers.count <= 16 else {
      throw GatewayFailure(code: .capacityExceeded, message: "Too many tool server health entries.")
    }
    var identifiers = Set<String>()
    for server in servers {
      _ = try server.validated()
      guard identifiers.insert(server.serverID).inserted else {
        throw GatewayFailure(
          code: .malformedPayload, message: "Duplicate tool server health entries.")
      }
    }
    return self
  }
}
