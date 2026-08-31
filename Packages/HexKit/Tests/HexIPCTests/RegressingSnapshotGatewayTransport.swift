import HexCore
import HexIPC

actor RegressingSnapshotGatewayTransport: HexGatewayTransport {
  let runID = GatewayTestValues.runID(210)
  let invocationID = GatewayTestValues.invocationID(210)
  private let instanceID = GatewayInstanceID(rawValue: GatewayTestValues.uuid(211))
  private var handshakeCount = 0

  func handshake(
    _ request: GatewayHandshakeRequest,
    lease: GatewayTransportConnectionLease
  ) -> GatewayHandshakeResponse {
    handshakeCount += 1
    return GatewayHandshakeResponse(
      sessionID: GatewaySessionID(
        rawValue: GatewayTestValues.uuid(UInt8(211 + handshakeCount))
      ),
      gatewayInstanceID: instanceID,
      selectedVersion: .current,
      activeRun: handshakeCount == 1
        ? nil
        : GatewayRunSnapshot(
          runID: runID,
          invocationID: invocationID,
          phase: .running,
          latestSequence: 1
        )
    )
  }

  func startRun(
    _ request: GatewayStartRunRequest,
    lease: GatewayTransportConnectionLease
  ) -> GatewayStartRunResponse {
    GatewayStartRunResponse(
      runID: request.runID,
      disposition: .alreadyRunning(invocationID: invocationID)
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
      continuation.yield(
        GatewayEventEnvelope(
          invocationID: cursor.invocationID,
          record: GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted)
        )
      )
      continuation.yield(
        GatewayEventEnvelope(
          invocationID: cursor.invocationID,
          record: GatewayTestValues.record(runID: runID, sequence: 2, event: .runCompleted)
        )
      )
      continuation.finish()
    }
  }

  func disconnect(lease: GatewayTransportConnectionLease) {}
}
