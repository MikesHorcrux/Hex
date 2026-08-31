import HexCore
import HexIPC

actor FakeHexGatewayTransport: HexGatewayTransport {
  private var handshakeResponses: [GatewayHandshakeResponse]
  private var recordsByRun: [AgentRunID: [AgentEventRecord]]
  private var cursors: [GatewayEventCursor] = []
  private var connected = false

  init(
    handshakeResponses: [GatewayHandshakeResponse],
    recordsByRun: [AgentRunID: [AgentEventRecord]] = [:]
  ) {
    self.handshakeResponses = handshakeResponses
    self.recordsByRun = recordsByRun
  }

  func handshake(_ request: GatewayHandshakeRequest) throws -> GatewayHandshakeResponse {
    guard !handshakeResponses.isEmpty else {
      throw GatewayFailure(
        code: .disconnected,
        message: "No scripted handshake response remains."
      )
    }
    connected = true
    return handshakeResponses.removeFirst()
  }

  func startRun(_ request: GatewayStartRunRequest) throws -> GatewayStartRunResponse {
    try requireConnection()
    return GatewayStartRunResponse(runID: request.runID, disposition: .started)
  }

  func cancelRun(_ request: GatewayCancelRunRequest) throws -> GatewayCancelRunResponse {
    try requireConnection()
    return GatewayCancelRunResponse(runID: request.runID, disposition: .requested)
  }

  func eventRecords(
    after cursor: GatewayEventCursor
  ) throws -> AsyncThrowingStream<AgentEventRecord, any Error> {
    try requireConnection()
    cursors.append(cursor)
    let records = recordsByRun[cursor.runID, default: []].filter {
      $0.sequence > cursor.sequence
    }
    return AsyncThrowingStream { continuation in
      for record in records {
        continuation.yield(record)
      }
      continuation.finish()
    }
  }

  func disconnect() {
    connected = false
  }

  func requestedCursors() -> [GatewayEventCursor] {
    cursors
  }

  private func requireConnection() throws {
    guard connected else {
      throw GatewayFailure(
        code: .notConnected,
        message: "The fake transport is disconnected."
      )
    }
  }
}
