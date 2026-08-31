import HexCore
import HexIPC

actor MalformedStartGatewayTransport: HexGatewayTransport {
  private let disposition: GatewayStartRunDisposition
  private let activeRun: GatewayRunSnapshot?

  init(
    disposition: GatewayStartRunDisposition,
    activeRun: GatewayRunSnapshot? = nil
  ) {
    self.disposition = disposition
    self.activeRun = activeRun
  }

  func handshake(
    _ request: GatewayHandshakeRequest,
    lease: GatewayTransportConnectionLease
  ) -> GatewayHandshakeResponse {
    GatewayHandshakeResponse(
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(200)),
      gatewayInstanceID: GatewayInstanceID(rawValue: GatewayTestValues.uuid(201)),
      selectedVersion: .current,
      activeRun: activeRun
    )
  }

  func startRun(
    _ request: GatewayStartRunRequest,
    lease: GatewayTransportConnectionLease
  ) -> GatewayStartRunResponse {
    GatewayStartRunResponse(runID: request.runID, disposition: disposition)
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
