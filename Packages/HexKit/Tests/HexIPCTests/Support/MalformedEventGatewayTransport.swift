import HexCore
import HexIPC

actor MalformedEventGatewayTransport: HexGatewayTransport {
  private let records: [AgentEventRecord]
  private let invocationID: GatewayRunInvocationID?
  private(set) var eventRequestCount = 0

  init(
    records: [AgentEventRecord],
    invocationID: GatewayRunInvocationID? = nil
  ) {
    self.records = records
    self.invocationID = invocationID
  }

  func handshake(
    _ request: GatewayHandshakeRequest,
    lease: GatewayTransportConnectionLease
  ) -> GatewayHandshakeResponse {
    GatewayHandshakeResponse(
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(190)),
      gatewayInstanceID: GatewayInstanceID(rawValue: GatewayTestValues.uuid(191)),
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
      disposition: .started(invocationID: GatewayTestValues.invocationID(190))
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
    eventRequestCount += 1
    return AsyncThrowingStream { continuation in
      for record in records {
        continuation.yield(
          GatewayEventEnvelope(
            invocationID: invocationID ?? cursor.invocationID,
            record: record
          )
        )
      }
      continuation.finish()
    }
  }

  func disconnect(lease: GatewayTransportConnectionLease) {}
}
