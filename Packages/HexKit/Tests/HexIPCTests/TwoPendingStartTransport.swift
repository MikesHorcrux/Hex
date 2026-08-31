import HexCore
import HexIPC

actor TwoPendingStartTransport: HexGatewayTransport {
  private var nextStartIndex = 0
  private var continuations: [Int: CheckedContinuation<GatewayStartRunResponse, Never>] = [:]
  private var runIDs: [Int: AgentRunID] = [:]

  func handshake(
    _ request: GatewayHandshakeRequest,
    lease: GatewayTransportConnectionLease
  ) -> GatewayHandshakeResponse {
    GatewayHandshakeResponse(
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(94)),
      gatewayInstanceID: GatewayInstanceID(rawValue: GatewayTestValues.uuid(94)),
      selectedVersion: .current,
      activeRun: nil
    )
  }

  func startRun(
    _ request: GatewayStartRunRequest,
    lease: GatewayTransportConnectionLease
  ) async -> GatewayStartRunResponse {
    nextStartIndex += 1
    let index = nextStartIndex
    runIDs[index] = request.runID
    return await withCheckedContinuation { continuation in
      continuations[index] = continuation
    }
  }

  func cancelRun(
    _ request: GatewayCancelRunRequest,
    lease: GatewayTransportConnectionLease
  ) -> GatewayCancelRunResponse {
    GatewayCancelRunResponse(
      runID: request.runID,
      invocationID: request.invocationID,
      disposition: .requested
    )
  }

  func eventRecords(
    after cursor: GatewayEventCursor,
    lease: GatewayTransportConnectionLease
  ) -> AsyncThrowingStream<AgentEventRecord, any Error> {
    AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }

  func disconnect(lease: GatewayTransportConnectionLease) {}

  func waitUntilPending(_ index: Int) async {
    while continuations[index] == nil {
      await Task.yield()
    }
  }

  func release(_ index: Int, invocationID: GatewayRunInvocationID) {
    guard let continuation = continuations.removeValue(forKey: index),
      let runID = runIDs.removeValue(forKey: index)
    else {
      return
    }
    continuation.resume(
      returning: GatewayStartRunResponse(
        runID: runID,
        disposition: .started(invocationID: invocationID)
      )
    )
  }
}
