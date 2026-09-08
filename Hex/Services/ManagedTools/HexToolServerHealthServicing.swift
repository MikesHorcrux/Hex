import HexIPC

/// Observes or explicitly checks the running resident's tools. Never establishes a connection.
nonisolated protocol HexToolServerHealthServicing: Sendable {
  func toolServerHealth() async throws -> GatewayToolServerHealth
  func refreshToolServer(_ request: GatewayToolServerRequest) async throws
    -> GatewayToolServerStatus
}
