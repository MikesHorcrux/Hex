public protocol HexGatewayToolServerControlTransport: Sendable {
  func toolServerHealth(lease: GatewayTransportConnectionLease) async throws
    -> GatewayToolServerHealth
  func refreshToolServer(
    _ request: GatewayToolServerRequest, lease: GatewayTransportConnectionLease
  )
    async throws -> GatewayToolServerStatus
}
