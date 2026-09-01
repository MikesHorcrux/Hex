import HexCore
import HexIPC

actor VersionCapturingGatewayTransport: HexGatewayTransport {
  private(set) var receivedRequest: GatewayHandshakeRequest?

  func handshake(
    _ request: GatewayHandshakeRequest,
    lease: GatewayTransportConnectionLease
  ) -> GatewayHandshakeResponse {
    receivedRequest = request
    return GatewayHandshakeResponse(
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(220)),
      gatewayInstanceID: GatewayInstanceID(rawValue: GatewayTestValues.uuid(221)),
      selectedVersion: .current,
      activeRun: nil
    )
  }

  func startRun(
    _ request: GatewayStartRunRequest,
    lease: GatewayTransportConnectionLease
  ) -> GatewayStartRunResponse {
    GatewayStartRunResponse(
      runID: request.runID,
      disposition: .started(invocationID: GatewayTestValues.invocationID(220))
    )
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
  ) -> AsyncThrowingStream<GatewayEventEnvelope, any Error> {
    AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }

  func disconnect(lease: GatewayTransportConnectionLease) {}
}
