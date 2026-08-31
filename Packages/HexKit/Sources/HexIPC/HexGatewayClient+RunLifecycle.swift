import HexCore

extension HexGatewayClient {
  /// Starts a run through the transport. For the same run identifier, a newer concurrent call
  /// supersedes every older in-flight call. Superseded responses and failures are redacted and can
  /// never mutate acknowledgement state belonging to the newer call.
  public func startRun(
    _ request: GatewayStartRunRequest
  ) async throws -> GatewayStartRunResponse {
    try Task.checkCancellation()
    let runID = request.runID
    let generationID = try requireConnectedGeneration()
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

      try requireCurrentConnectedGeneration(generationID)
      try requireCurrentStartAttempt(for: runID, matching: attemptID)
      try Task.checkCancellation()
      invalidateStartAttempt(for: runID, matching: attemptID)
      throw error
    }

    try Task.checkCancellation()
    try requireCurrentConnectedGeneration(generationID)
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
    try Task.checkCancellation()
    let generationID = try requireConnectedGeneration()

    let response: GatewayCancelRunResponse
    do {
      response = try await transport.cancelRun(request)
    } catch {
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(generationID)
      throw error
    }

    try Task.checkCancellation()
    try requireCurrentConnectedGeneration(generationID)
    guard response.runID == request.runID else {
      throw GatewayFailure(
        code: .wrongRun,
        message: "The gateway returned a cancellation response for a different run."
      )
    }
    guard response.invocationID == request.invocationID else {
      throw GatewayFailure(
        code: .staleRunInvocation,
        message: "The gateway returned a cancellation response for a different run invocation."
      )
    }
    try Task.checkCancellation()
    try requireCurrentConnectedGeneration(generationID)
    return response
  }

  func requireCurrentStartAttempt(
    for runID: AgentRunID,
    matching attemptID: GatewayClientStartAttemptID
  ) throws {
    guard startAttemptIDs[runID] == attemptID else {
      throw supersededOperationFailure()
    }
  }

  func invalidateStartAttempt(
    for runID: AgentRunID,
    matching attemptID: GatewayClientStartAttemptID
  ) {
    guard startAttemptIDs[runID] == attemptID else {
      return
    }
    startAttemptIDs.removeValue(forKey: runID)
  }
}
