import HexCore

/// A process-neutral app-to-gateway boundary. The current implementation is same-process only; this
/// protocol does not imply XPC isolation, app-independent persistence, or expanded privileges.
public protocol HexGatewayTransport: Sendable {
  func handshake(
    _ request: GatewayHandshakeRequest,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayHandshakeResponse

  func startRun(
    _ request: GatewayStartRunRequest,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayStartRunResponse

  func cancelRun(
    _ request: GatewayCancelRunRequest,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayCancelRunResponse

  func eventRecords(
    after cursor: GatewayEventCursor,
    lease: GatewayTransportConnectionLease
  ) async throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error>

  /// Disconnects only the physical connection still owned by `lease`. Implementations must compare
  /// ownership again at the destructive mutation point after every suspension and ignore stale
  /// leases. Disconnect is nonthrowing at this boundary; stale leases are an expected race.
  func disconnect(lease: GatewayTransportConnectionLease) async
}
