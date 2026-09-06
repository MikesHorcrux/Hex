/// Optional read-only recovery operations bound to the current local session and physical lease.
public protocol HexGatewayRunRecoveryTransport: Sendable {
  func recoverRun(_ request: GatewayRunRecoveryRequest, lease: GatewayTransportConnectionLease)
    async throws -> GatewayRunRecoveryResponse
  func readRunHistory(_ request: GatewayRunHistoryRequest, lease: GatewayTransportConnectionLease)
    async throws -> GatewayRunHistoryPage
}
