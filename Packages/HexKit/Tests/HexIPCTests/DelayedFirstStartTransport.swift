import HexCore
import HexIPC

actor DelayedFirstStartTransport: HexGatewayTransport {
  private let base: InProcessHexGatewayTransport
  private var startCount = 0
  private var heldResponse: GatewayStartRunResponse?
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  init(base: InProcessHexGatewayTransport) {
    self.base = base
  }

  func handshake(
    _ request: GatewayHandshakeRequest,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayHandshakeResponse {
    try await base.handshake(request, lease: lease)
  }

  func startRun(
    _ request: GatewayStartRunRequest,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayStartRunResponse {
    startCount += 1
    let response = try await base.startRun(request, lease: lease)
    guard startCount == 1 else {
      return response
    }

    heldResponse = response
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
    return response
  }

  func cancelRun(
    _ request: GatewayCancelRunRequest,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayCancelRunResponse {
    try await base.cancelRun(request, lease: lease)
  }

  func eventRecords(
    after cursor: GatewayEventCursor,
    lease: GatewayTransportConnectionLease
  ) async throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error> {
    try await base.eventRecords(after: cursor, lease: lease)
  }

  func disconnect(lease: GatewayTransportConnectionLease) async {
    await base.disconnect(lease: lease)
  }

  func waitUntilFirstResponseIsHeld() async {
    while heldResponse == nil {
      await Task.yield()
    }
  }

  func releaseFirstResponse() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}
