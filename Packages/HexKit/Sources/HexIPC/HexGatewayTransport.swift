import HexCore

/// A process-neutral app-to-gateway boundary. The current implementation is same-process only; this
/// protocol does not imply XPC isolation, app-independent persistence, or expanded privileges.
public protocol HexGatewayTransport: Sendable {
  func handshake(_ request: GatewayHandshakeRequest) async throws -> GatewayHandshakeResponse

  func startRun(_ request: GatewayStartRunRequest) async throws -> GatewayStartRunResponse

  func cancelRun(_ request: GatewayCancelRunRequest) async throws -> GatewayCancelRunResponse

  func eventRecords(
    after cursor: GatewayEventCursor
  ) async throws -> AsyncThrowingStream<AgentEventRecord, any Error>

  func disconnect() async
}
