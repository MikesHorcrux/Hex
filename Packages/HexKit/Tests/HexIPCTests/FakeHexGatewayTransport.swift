import HexCore
import HexIPC

actor FakeHexGatewayTransport: HexGatewayTransport {
  private var handshakeResponses: [GatewayHandshakeResponse]
  private var recordsByRun: [AgentRunID: [AgentEventRecord]]
  private var cursors: [GatewayEventCursor] = []
  private var connectedLease: GatewayTransportConnectionLease?

  init(
    handshakeResponses: [GatewayHandshakeResponse],
    recordsByRun: [AgentRunID: [AgentEventRecord]] = [:]
  ) {
    self.handshakeResponses = handshakeResponses
    self.recordsByRun = recordsByRun
  }

  func handshake(
    _ request: GatewayHandshakeRequest,
    lease: GatewayTransportConnectionLease
  ) throws -> GatewayHandshakeResponse {
    guard !handshakeResponses.isEmpty else {
      throw GatewayFailure(
        code: .disconnected,
        message: "No scripted handshake response remains."
      )
    }
    connectedLease = lease
    return handshakeResponses.removeFirst()
  }

  func startRun(
    _ request: GatewayStartRunRequest,
    lease: GatewayTransportConnectionLease
  ) throws -> GatewayStartRunResponse {
    try requireConnection(lease: lease)
    return GatewayStartRunResponse(
      runID: request.runID,
      disposition: .started(invocationID: GatewayTestValues.invocationID())
    )
  }

  func cancelRun(
    _ request: GatewayCancelRunRequest,
    lease: GatewayTransportConnectionLease
  ) throws -> GatewayCancelRunResponse {
    try requireConnection(lease: lease)
    return GatewayCancelRunResponse(
      runID: request.runID,
      invocationID: request.invocationID,
      disposition: .requested
    )
  }

  func eventRecords(
    after cursor: GatewayEventCursor,
    lease: GatewayTransportConnectionLease
  ) throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error> {
    try requireConnection(lease: lease)
    cursors.append(cursor)
    let records = recordsByRun[cursor.runID, default: []].filter {
      $0.sequence > cursor.sequence
    }
    return AsyncThrowingStream { continuation in
      for record in records {
        continuation.yield(
          GatewayEventEnvelope(invocationID: cursor.invocationID, record: record)
        )
      }
      continuation.finish()
    }
  }

  func disconnect(lease: GatewayTransportConnectionLease) {
    guard connectedLease == lease else {
      return
    }
    connectedLease = nil
  }

  func requestedCursors() -> [GatewayEventCursor] {
    cursors
  }

  private func requireConnection(lease: GatewayTransportConnectionLease) throws {
    guard connectedLease == lease else {
      throw GatewayFailure(
        code: .notConnected,
        message: "The fake transport is disconnected."
      )
    }
  }
}
