import HexCore
import HexIPC

actor MismatchedStartGatewayTransport: HexGatewayTransport {
  private let responseRunID: AgentRunID
  private let invocationID: GatewayRunInvocationID

  init(
    responseRunID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) {
    self.responseRunID = responseRunID
    self.invocationID = invocationID
  }

  func handshake(_ request: GatewayHandshakeRequest) -> GatewayHandshakeResponse {
    GatewayHandshakeResponse(
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(93)),
      gatewayInstanceID: GatewayInstanceID(rawValue: GatewayTestValues.uuid(93)),
      selectedVersion: .current,
      activeRun: nil
    )
  }

  func startRun(_ request: GatewayStartRunRequest) -> GatewayStartRunResponse {
    GatewayStartRunResponse(
      runID: responseRunID,
      disposition: .started(invocationID: invocationID)
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
}
