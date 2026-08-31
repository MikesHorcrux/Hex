import Foundation
import HexCore

extension HexGatewayClient {
  /// Starts a run through the transport. For the same run identifier, a newer concurrent call
  /// supersedes every older in-flight call. Superseded responses and failures are redacted and can
  /// never mutate acknowledgement state belonging to the newer call.
  public func startRun(
    _ request: GatewayStartRunRequest
  ) async throws -> GatewayStartRunResponse {
    try Task.checkCancellation()
    try validateStartRequest(request)
    let runID = request.runID
    let connection = try requireConnectedGeneration()
    let attemptID = GatewayClientStartAttemptID()
    startAttemptIDs[runID] = attemptID

    let response: GatewayStartRunResponse
    do {
      response = try await withTaskCancellationHandler {
        try await transport.startRun(request, lease: connection.lease)
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

      try requireCurrentConnectedGeneration(connection.generationID)
      try requireCurrentStartAttempt(for: runID, matching: attemptID)
      try Task.checkCancellation()
      invalidateStartAttempt(for: runID, matching: attemptID)
      throw error
    }

    try Task.checkCancellation()
    try requireCurrentConnectedGeneration(connection.generationID)
    try requireCurrentStartAttempt(for: runID, matching: attemptID)
    do {
      try validateStartResponse(response, for: request)
    } catch {
      try Task.checkCancellation()
      invalidateStartAttempt(for: runID, matching: attemptID)
      throw error
    }

    try Task.checkCancellation()
    switch response.disposition {
    case .started(let invocationID):
      // A newly admitted generation always begins at cursor zero, even when its run identifier was
      // previously acknowledged before bounded service eviction.
      removeAcknowledgements(for: response.runID)
      storeAcknowledgement(
        0,
        for: GatewayRunAcknowledgementKey(
          runID: response.runID,
          invocationID: invocationID
        )
      )
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
    try validateCancellationRequest(request)
    let connection = try requireConnectedGeneration()

    let response: GatewayCancelRunResponse
    do {
      response = try await transport.cancelRun(request, lease: connection.lease)
    } catch {
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      throw error
    }

    try Task.checkCancellation()
    try requireCurrentConnectedGeneration(connection.generationID)
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
    try requireCurrentConnectedGeneration(connection.generationID)
    return response
  }

  func validateStartRequest(_ request: GatewayStartRunRequest) throws {
    guard !isZero(request.runID.rawValue) else {
      throw malformedStartResponseFailure()
    }
  }

  func validateStartResponse(
    _ response: GatewayStartRunResponse,
    for request: GatewayStartRunRequest
  ) throws {
    guard response.runID == request.runID else {
      throw GatewayFailure(
        code: .wrongRun,
        message: "The gateway returned a start response for a different run."
      )
    }
    guard !isZero(response.runID.rawValue) else {
      throw malformedStartResponseFailure()
    }

    switch response.disposition {
    case .started(let invocationID),
      .alreadyRunning(let invocationID),
      .alreadyTerminal(let invocationID):
      guard !isZero(invocationID.rawValue) else {
        throw malformedStartResponseFailure()
      }
    case .busy(let activeRunID):
      guard !isZero(activeRunID.rawValue), activeRunID != request.runID else {
        throw malformedStartResponseFailure()
      }
    }
  }

  func validateCancellationRequest(_ request: GatewayCancelRunRequest) throws {
    guard !isZero(request.runID.rawValue), !isZero(request.invocationID.rawValue) else {
      throw GatewayFailure(
        code: .malformedPayload,
        message: "The gateway cancellation request contains an invalid identity."
      )
    }
  }

  func malformedStartResponseFailure() -> GatewayFailure {
    GatewayFailure(
      code: .malformedPayload,
      message: "The gateway returned an invalid start response."
    )
  }

  func isZero(_ value: UUID) -> Bool {
    value == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
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
