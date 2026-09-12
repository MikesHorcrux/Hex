import HexCore

public protocol HexGatewayProcessSessionTransport: Sendable {
  func processSession(
    _ request: GatewayProcessSessionRequest, lease: GatewayTransportConnectionLease
  )
    async throws -> GatewayProcessSessionResponse
}
