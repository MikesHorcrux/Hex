import Foundation

extension HexGatewayClient {
  public func connect() async throws -> GatewayConnectionResult {
    try Task.checkCancellation()
    let attemptID = GatewayClientConnectionAttemptID()
    let generationID = advanceConnection(attemptID: attemptID)
    do {
      try validateHandshakeRequest()
    } catch {
      invalidateConnectionAttempt(matching: attemptID, generationID: generationID)
      throw error
    }

    let response: GatewayHandshakeResponse
    do {
      response = try await withTaskCancellationHandler {
        try await transport.handshake(handshakeRequest)
      } onCancel: {
        Task {
          await self.invalidateConnectionAttempt(
            matching: attemptID,
            generationID: generationID
          )
        }
      }
    } catch {
      if Task.isCancelled {
        invalidateConnectionAttempt(matching: attemptID, generationID: generationID)
        throw CancellationError()
      }

      try requireCurrentConnectionAttempt(attemptID, generationID: generationID)
      try Task.checkCancellation()
      invalidateConnectionAttempt(matching: attemptID, generationID: generationID)
      throw error
    }

    try Task.checkCancellation()
    try requireCurrentConnectionAttempt(attemptID, generationID: generationID)
    do {
      try validateHandshake(response)
    } catch {
      try Task.checkCancellation()
      try requireCurrentConnectionAttempt(attemptID, generationID: generationID)
      invalidateConnectionAttempt(matching: attemptID, generationID: generationID)
      throw error
    }

    let previousGatewayInstanceID = gatewayInstanceID
    try Task.checkCancellation()
    try requireCurrentConnectionAttempt(attemptID, generationID: generationID)
    if let previousGatewayInstanceID,
      previousGatewayInstanceID != response.gatewayInstanceID
    {
      acknowledgedSequences.removeAll()
    }
    gatewayInstanceID = response.gatewayInstanceID
    connectedGenerationID = generationID
    connectionAttemptID = nil
    return GatewayConnectionResult(
      response: response,
      previousGatewayInstanceID: previousGatewayInstanceID
    )
  }

  /// Invalidates the current connection generation before asking the transport to disconnect.
  /// Work from the invalidated generation cannot commit even if the transport ignores cancellation.
  public func disconnect() async throws {
    try Task.checkCancellation()
    let attemptID = GatewayClientConnectionAttemptID()
    let generationID = advanceConnection(attemptID: attemptID)
    await withTaskCancellationHandler {
      await transport.disconnect()
    } onCancel: {
      Task {
        await self.invalidateConnectionAttempt(
          matching: attemptID,
          generationID: generationID
        )
      }
    }

    try Task.checkCancellation()
    try requireCurrentConnectionAttempt(attemptID, generationID: generationID)
    connectionAttemptID = nil
  }

  func advanceConnection(
    attemptID: GatewayClientConnectionAttemptID
  ) -> GatewayClientConnectionGenerationID {
    let generationID = GatewayClientConnectionGenerationID()
    connectionGenerationID = generationID
    connectedGenerationID = nil
    connectionAttemptID = attemptID
    startAttemptIDs.removeAll()
    terminateEventStreamsForConnectionChange()
    return generationID
  }

  func invalidateConnectionAttempt(
    matching attemptID: GatewayClientConnectionAttemptID,
    generationID: GatewayClientConnectionGenerationID
  ) {
    guard connectionAttemptID == attemptID, connectionGenerationID == generationID else {
      return
    }
    connectionAttemptID = nil
    connectedGenerationID = nil
  }

  func requireCurrentConnectionAttempt(
    _ attemptID: GatewayClientConnectionAttemptID,
    generationID: GatewayClientConnectionGenerationID
  ) throws {
    guard connectionAttemptID == attemptID, connectionGenerationID == generationID else {
      throw supersededOperationFailure()
    }
  }

  func requireConnectedGeneration() throws -> GatewayClientConnectionGenerationID {
    guard let connectedGenerationID, connectedGenerationID == connectionGenerationID else {
      throw GatewayFailure(
        code: .notConnected,
        message: "The gateway client is not connected."
      )
    }
    return connectedGenerationID
  }

  func requireCurrentConnectedGeneration(
    _ generationID: GatewayClientConnectionGenerationID
  ) throws {
    guard connectionGenerationID == generationID, connectedGenerationID == generationID else {
      throw supersededOperationFailure()
    }
  }

  func validateHandshakeRequest() throws {
    guard handshakeRequest.minimumVersion <= handshakeRequest.maximumVersion else {
      throw GatewayFailure(
        code: .malformedVersionRange,
        message: "The gateway client protocol version range is malformed."
      )
    }
  }

  func validateHandshake(_ response: GatewayHandshakeResponse) throws {
    guard response.selectedVersion >= handshakeRequest.minimumVersion,
      response.selectedVersion <= handshakeRequest.maximumVersion
    else {
      throw GatewayFailure(
        code: .incompatibleProtocolVersion,
        message: "The gateway selected a protocol version the client did not offer."
      )
    }

    let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    guard response.sessionID.rawValue != zeroUUID,
      response.gatewayInstanceID.rawValue != zeroUUID
    else {
      throw invalidHandshakeFailure()
    }
    guard let activeRun = response.activeRun else {
      return
    }
    guard activeRun.runID.rawValue != zeroUUID,
      activeRun.invocationID.rawValue != zeroUUID,
      activeRun.latestSequence != UInt64.max
    else {
      throw invalidHandshakeFailure()
    }
    switch activeRun.phase {
    case .starting:
      guard activeRun.latestSequence == 0 else {
        throw invalidHandshakeFailure()
      }
    case .running:
      guard activeRun.latestSequence > 0 else {
        throw invalidHandshakeFailure()
      }
    case .cancelling:
      break
    case .terminal:
      throw invalidHandshakeFailure()
    }
  }

  func invalidHandshakeFailure() -> GatewayFailure {
    GatewayFailure(
      code: .malformedPayload,
      message: "The gateway returned an invalid handshake response."
    )
  }
}
