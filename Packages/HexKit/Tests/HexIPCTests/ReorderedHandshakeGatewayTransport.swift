import HexCore
import HexIPC

actor ReorderedHandshakeGatewayTransport: HexGatewayTransport {
  private let initialInstanceID = GatewayInstanceID(rawValue: GatewayTestValues.uuid(201))
  private let delayedInstanceID = GatewayInstanceID(rawValue: GatewayTestValues.uuid(202))
  private let currentInstanceID = GatewayInstanceID(rawValue: GatewayTestValues.uuid(203))
  private var handshakeCount = 0
  private var delayedContinuation: CheckedContinuation<GatewayHandshakeResponse, Never>?

  func handshake(_ request: GatewayHandshakeRequest) async -> GatewayHandshakeResponse {
    handshakeCount += 1
    switch handshakeCount {
    case 1:
      return response(instanceID: initialInstanceID, sessionSeed: 201)
    case 2:
      return await withCheckedContinuation { continuation in
        delayedContinuation = continuation
      }
    default:
      return response(instanceID: currentInstanceID, sessionSeed: 203)
    }
  }

  func startRun(_ request: GatewayStartRunRequest) -> GatewayStartRunResponse {
    GatewayStartRunResponse(
      runID: request.runID,
      disposition: .started(invocationID: GatewayTestValues.invocationID(201))
    )
  }

  func cancelRun(_ request: GatewayCancelRunRequest) -> GatewayCancelRunResponse {
    GatewayCancelRunResponse(
      runID: request.runID,
      invocationID: request.invocationID,
      disposition: .requested
    )
  }

  func eventRecords(
    after cursor: GatewayEventCursor
  ) -> AsyncThrowingStream<AgentEventRecord, any Error> {
    AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }

  func disconnect() {}

  func waitUntilDelayedHandshakeIsPending() async {
    while delayedContinuation == nil {
      await Task.yield()
    }
  }

  func releaseDelayedHandshake() {
    delayedContinuation?.resume(
      returning: response(instanceID: delayedInstanceID, sessionSeed: 202)
    )
    delayedContinuation = nil
  }

  private func response(
    instanceID: GatewayInstanceID,
    sessionSeed: UInt8
  ) -> GatewayHandshakeResponse {
    GatewayHandshakeResponse(
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(sessionSeed)),
      gatewayInstanceID: instanceID,
      selectedVersion: .current,
      activeRun: nil
    )
  }
}
