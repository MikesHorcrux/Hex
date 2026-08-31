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

  func handshake(_ request: GatewayHandshakeRequest) async throws -> GatewayHandshakeResponse {
    try await base.handshake(request)
  }

  func startRun(_ request: GatewayStartRunRequest) async throws -> GatewayStartRunResponse {
    startCount += 1
    let response = try await base.startRun(request)
    guard startCount == 1 else {
      return response
    }

    heldResponse = response
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
    return response
  }

  func cancelRun(_ request: GatewayCancelRunRequest) async throws -> GatewayCancelRunResponse {
    try await base.cancelRun(request)
  }

  func eventRecords(
    after cursor: GatewayEventCursor
  ) async throws -> AsyncThrowingStream<AgentEventRecord, any Error> {
    try await base.eventRecords(after: cursor)
  }

  func disconnect() async {
    await base.disconnect()
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
