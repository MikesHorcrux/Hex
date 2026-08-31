import HexCore

/// App-facing gateway client with in-memory, explicitly acknowledged replay cursors. Cursor state is
/// not durable across app termination; callers must apply each record before acknowledging it.
public actor HexGatewayClient {
  private let transport: any HexGatewayTransport
  private let handshakeRequest: GatewayHandshakeRequest
  private var gatewayInstanceID: GatewayInstanceID?
  private var acknowledgedSequences: [AgentRunID: UInt64] = [:]

  public init(
    transport: any HexGatewayTransport,
    clientID: GatewayClientID = GatewayClientID(),
    minimumVersion: GatewayProtocolVersion = .minimumSupported,
    maximumVersion: GatewayProtocolVersion = .current
  ) {
    self.transport = transport
    handshakeRequest = GatewayHandshakeRequest(
      clientID: clientID,
      minimumVersion: minimumVersion,
      maximumVersion: maximumVersion
    )
  }

  public func connect() async throws -> GatewayConnectionResult {
    let previousGatewayInstanceID = gatewayInstanceID
    let response = try await transport.handshake(handshakeRequest)
    if let previousGatewayInstanceID,
      previousGatewayInstanceID != response.gatewayInstanceID
    {
      acknowledgedSequences.removeAll()
    }
    gatewayInstanceID = response.gatewayInstanceID
    return GatewayConnectionResult(
      response: response,
      previousGatewayInstanceID: previousGatewayInstanceID
    )
  }

  public func startRun(
    _ request: GatewayStartRunRequest
  ) async throws -> GatewayStartRunResponse {
    try await transport.startRun(request)
  }

  public func cancelRun(
    _ request: GatewayCancelRunRequest
  ) async throws -> GatewayCancelRunResponse {
    try await transport.cancelRun(request)
  }

  public func eventRecords(
    for runID: AgentRunID
  ) async throws -> AsyncThrowingStream<AgentEventRecord, any Error> {
    try await transport.eventRecords(after: acknowledgedCursor(for: runID))
  }

  public func acknowledgedCursor(for runID: AgentRunID) -> GatewayEventCursor {
    GatewayEventCursor(runID: runID, sequence: acknowledgedSequences[runID] ?? 0)
  }

  /// Returns false for an already-applied record and fails closed if applying the record would skip a
  /// sequence. A true result does not advance the cursor; call `acknowledge` only after reduction.
  public func shouldApply(_ record: AgentEventRecord) throws -> Bool {
    let acknowledgedSequence = acknowledgedSequences[record.runID] ?? 0
    if record.sequence <= acknowledgedSequence {
      return false
    }

    let expectedSequence = acknowledgedSequence.addingReportingOverflow(1)
    guard !expectedSequence.overflow, record.sequence == expectedSequence.partialValue else {
      throw GatewayFailure(
        code: .invalidEventSequence,
        message: "The client cannot apply an event record with a sequence gap."
      )
    }
    return true
  }

  public func acknowledge(_ record: AgentEventRecord) throws {
    let acknowledgedSequence = acknowledgedSequences[record.runID] ?? 0
    if record.sequence <= acknowledgedSequence {
      return
    }

    let expectedSequence = acknowledgedSequence.addingReportingOverflow(1)
    guard !expectedSequence.overflow, record.sequence == expectedSequence.partialValue else {
      throw GatewayFailure(
        code: .invalidEventSequence,
        message: "The client cannot acknowledge an event record with a sequence gap."
      )
    }
    acknowledgedSequences[record.runID] = record.sequence
  }

  public func forgetAcknowledgement(for runID: AgentRunID) {
    acknowledgedSequences.removeValue(forKey: runID)
  }

  public func disconnect() async {
    await transport.disconnect()
  }
}
