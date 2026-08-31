import HexCore

extension HexGatewayTransport {
  /// Convenience for direct transport tests and diagnostics that use one serial connection. Agent
  /// clients use explicit per-generation leases instead.
  public func handshake(
    _ request: GatewayHandshakeRequest
  ) async throws -> GatewayHandshakeResponse {
    try await handshake(request, lease: .unscoped)
  }

  public func startRun(
    _ request: GatewayStartRunRequest
  ) async throws -> GatewayStartRunResponse {
    try await startRun(request, lease: .unscoped)
  }

  public func cancelRun(
    _ request: GatewayCancelRunRequest
  ) async throws -> GatewayCancelRunResponse {
    try await cancelRun(request, lease: .unscoped)
  }

  public func eventRecords(
    after cursor: GatewayEventCursor
  ) async throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error> {
    try await eventRecords(after: cursor, lease: .unscoped)
  }

  public func disconnect() async {
    await disconnect(lease: .unscoped)
  }
}
