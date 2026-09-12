import HexIPC

extension HexGatewayClientAdapter: HexToolServerHealthServicing {
  func toolServerHealth() async throws -> GatewayToolServerHealth {
    try await client.toolServerHealth()
  }

  func refreshToolServer(_ request: GatewayToolServerRequest) async throws
    -> GatewayToolServerStatus
  {
    try await client.refreshToolServer(request)
  }
}
