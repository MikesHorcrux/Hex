import HexCore

/// App-facing gateway client with in-memory, explicitly acknowledged replay cursors keyed by exact
/// run invocation. Cursor state is not durable across app termination; callers must apply each record
/// before acknowledging it with the invocation identity that produced it.
public actor HexGatewayClient {
  private let transport: any HexGatewayTransport
  private let handshakeRequest: GatewayHandshakeRequest
  private var gatewayInstanceID: GatewayInstanceID?
  private var acknowledgedSequences: [GatewayRunAcknowledgementKey: UInt64] = [:]
  private var startAttemptIDs: [AgentRunID: GatewayClientStartAttemptID] = [:]

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

  /// Starts a run through the transport. For the same run identifier, a newer concurrent call
  /// supersedes every older in-flight call. Superseded responses and failures are redacted and can
  /// never mutate acknowledgement state belonging to the newer call.
  public func startRun(
    _ request: GatewayStartRunRequest
  ) async throws -> GatewayStartRunResponse {
    try Task.checkCancellation()
    let runID = request.runID
    let attemptID = GatewayClientStartAttemptID()
    startAttemptIDs[runID] = attemptID

    let response: GatewayStartRunResponse
    do {
      response = try await withTaskCancellationHandler {
        try await transport.startRun(request)
      } onCancel: {
        Task {
          await self.invalidateStartAttempt(
            for: runID,
            matching: attemptID
          )
        }
      }
    } catch {
      if Task.isCancelled {
        invalidateStartAttempt(for: runID, matching: attemptID)
        throw CancellationError()
      }

      try requireCurrentStartAttempt(for: runID, matching: attemptID)
      try Task.checkCancellation()
      invalidateStartAttempt(for: runID, matching: attemptID)
      throw error
    }

    try Task.checkCancellation()
    try requireCurrentStartAttempt(for: runID, matching: attemptID)
    guard response.runID == runID else {
      try Task.checkCancellation()
      invalidateStartAttempt(for: runID, matching: attemptID)
      throw GatewayFailure(
        code: .wrongRun,
        message: "The gateway returned a start response for a different run."
      )
    }

    try Task.checkCancellation()
    switch response.disposition {
    case .started(let invocationID):
      // A newly admitted generation always begins at cursor zero, even when its run identifier was
      // previously acknowledged before bounded service eviction.
      removeAcknowledgements(for: response.runID)
      acknowledgedSequences[
        GatewayRunAcknowledgementKey(runID: response.runID, invocationID: invocationID)
      ] = 0
    case .alreadyRunning(let invocationID), .alreadyTerminal(let invocationID):
      removeAcknowledgements(for: response.runID, except: invocationID)
    case .busy:
      break
    }
    invalidateStartAttempt(for: runID, matching: attemptID)
    return response
  }

  public func cancelRun(
    _ request: GatewayCancelRunRequest
  ) async throws -> GatewayCancelRunResponse {
    try await transport.cancelRun(request)
  }

  public func eventRecords(
    for runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) async throws -> AsyncThrowingStream<AgentEventRecord, any Error> {
    try await transport.eventRecords(
      after: acknowledgedCursor(for: runID, invocationID: invocationID)
    )
  }

  public func acknowledgedCursor(
    for runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) -> GatewayEventCursor {
    let key = GatewayRunAcknowledgementKey(runID: runID, invocationID: invocationID)
    return GatewayEventCursor(
      runID: runID,
      invocationID: invocationID,
      sequence: acknowledgedSequences[key] ?? 0
    )
  }

  /// Returns false for an already-applied record and fails closed if applying the record would skip a
  /// sequence. A true result does not advance the cursor; call `acknowledge` only after reduction.
  public func shouldApply(
    _ record: AgentEventRecord,
    invocationID: GatewayRunInvocationID
  ) throws -> Bool {
    let key = GatewayRunAcknowledgementKey(
      runID: record.runID,
      invocationID: invocationID
    )
    let acknowledgedSequence = acknowledgedSequences[key] ?? 0
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

  public func acknowledge(
    _ record: AgentEventRecord,
    invocationID: GatewayRunInvocationID
  ) throws {
    let key = GatewayRunAcknowledgementKey(
      runID: record.runID,
      invocationID: invocationID
    )
    let acknowledgedSequence = acknowledgedSequences[key] ?? 0
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
    acknowledgedSequences[key] = record.sequence
  }

  public func forgetAcknowledgement(
    for runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) {
    acknowledgedSequences.removeValue(
      forKey: GatewayRunAcknowledgementKey(
        runID: runID,
        invocationID: invocationID
      )
    )
  }

  public func disconnect() async {
    await transport.disconnect()
  }

  private func removeAcknowledgements(
    for runID: AgentRunID,
    except retainedInvocationID: GatewayRunInvocationID? = nil
  ) {
    acknowledgedSequences = acknowledgedSequences.filter { entry in
      entry.key.runID != runID || entry.key.invocationID == retainedInvocationID
    }
  }

  private func requireCurrentStartAttempt(
    for runID: AgentRunID,
    matching attemptID: GatewayClientStartAttemptID
  ) throws {
    guard startAttemptIDs[runID] == attemptID else {
      throw supersededStartFailure()
    }
  }

  private func invalidateStartAttempt(
    for runID: AgentRunID,
    matching attemptID: GatewayClientStartAttemptID
  ) {
    guard startAttemptIDs[runID] == attemptID else {
      return
    }
    startAttemptIDs.removeValue(forKey: runID)
  }

  private func supersededStartFailure() -> GatewayFailure {
    GatewayFailure(
      code: .supersededOperation,
      message: "The start operation was superseded by a newer attempt."
    )
  }
}
