import HexCore
import HexIPC

actor LateDisconnectGatewayTransport: HexGatewayTransport {
  private var connectedLease: GatewayTransportConnectionLease?
  private var handshakeCount: UInt8 = 0
  private var disconnectContinuation: CheckedContinuation<Void, Never>?

  func handshake(
    _ request: GatewayHandshakeRequest,
    lease: GatewayTransportConnectionLease
  ) -> GatewayHandshakeResponse {
    handshakeCount &+= 1
    connectedLease = lease
    let seed = 180 &+ handshakeCount
    return GatewayHandshakeResponse(
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(seed)),
      gatewayInstanceID: GatewayInstanceID(rawValue: GatewayTestValues.uuid(180)),
      selectedVersion: .current,
      activeRun: nil
    )
  }

  func startRun(
    _ request: GatewayStartRunRequest,
    lease: GatewayTransportConnectionLease
  ) throws -> GatewayStartRunResponse {
    guard connectedLease == lease else {
      throw tornDownFailure()
    }
    return GatewayStartRunResponse(
      runID: request.runID,
      disposition: .started(invocationID: GatewayTestValues.invocationID(181))
    )
  }

  func cancelRun(
    _ request: GatewayCancelRunRequest,
    lease: GatewayTransportConnectionLease
  ) throws -> GatewayCancelRunResponse {
    guard connectedLease == lease else {
      throw tornDownFailure()
    }
    return GatewayCancelRunResponse(
      runID: request.runID,
      invocationID: request.invocationID,
      disposition: .requested
    )
  }

  func eventRecords(
    after cursor: GatewayEventCursor,
    lease: GatewayTransportConnectionLease
  ) throws -> AsyncThrowingStream<AgentEventRecord, any Error> {
    guard connectedLease == lease else {
      throw tornDownFailure()
    }
    return AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }

  func disconnect(lease: GatewayTransportConnectionLease) async {
    await withCheckedContinuation { continuation in
      disconnectContinuation = continuation
    }
    guard connectedLease == lease else {
      return
    }
    connectedLease = nil
  }

  func waitUntilDisconnectIsPending() async {
    while disconnectContinuation == nil {
      await Task.yield()
    }
  }

  func releaseDisconnect() {
    disconnectContinuation?.resume()
    disconnectContinuation = nil
  }

  private func tornDownFailure() -> GatewayFailure {
    GatewayFailure(
      code: .transportUnavailable,
      message: "The delayed disconnect tore down the replacement connection."
    )
  }
}
