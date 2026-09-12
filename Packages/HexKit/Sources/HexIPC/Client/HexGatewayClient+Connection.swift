import Foundation

extension HexGatewayClient {
  public func connect() async throws -> GatewayConnectionResult {
    try Task.checkCancellation()
    let attemptID = GatewayClientConnectionAttemptID()
    let lease = GatewayTransportConnectionLease()
    let generationID = advanceConnection(attemptID: attemptID, lease: lease)
    do {
      try validateHandshakeRequest()
    } catch {
      invalidateConnectionAttempt(matching: attemptID, generationID: generationID)
      throw error
    }

    let response: GatewayHandshakeResponse
    do {
      response = try await withTaskCancellationHandler {
        try await transport.handshake(handshakeRequest, lease: lease)
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

    do {
      try Task.checkCancellation()
      try requireCurrentConnectionAttempt(attemptID, generationID: generationID)
      try validateHandshake(response)
      try Task.checkCancellation()
      try requireCurrentConnectionAttempt(attemptID, generationID: generationID)

      let previousGatewayInstanceID = gatewayInstanceID
      if let previousGatewayInstanceID,
        previousGatewayInstanceID != response.gatewayInstanceID
      {
        removeAllAcknowledgements()
      }
      if let activeRun = response.activeRun {
        let key = GatewayRunAcknowledgementKey(
          runID: activeRun.runID,
          invocationID: activeRun.invocationID
        )
        if acknowledgedSequences[key] == nil {
          storeAcknowledgement(0, for: key)
        }
      }
      gatewayInstanceID = response.gatewayInstanceID
      connectedProtocolVersion = response.selectedVersion
      connectedGenerationID = generationID
      connectedLease = lease
      connectionAttemptID = nil
      return GatewayConnectionResult(
        response: response,
        previousGatewayInstanceID: previousGatewayInstanceID
      )
    } catch {
      invalidateConnectionAttempt(matching: attemptID, generationID: generationID)
      await transport.disconnect(lease: lease)
      throw error
    }
  }

  /// Invalidates the current connection generation before asking the transport to disconnect.
  /// Work from the invalidated generation cannot commit even if the transport ignores cancellation.
  public func disconnect() async throws {
    try Task.checkCancellation()
    let disconnectedLease = connectionLease
    let attemptID = GatewayClientConnectionAttemptID()
    let generationID = advanceConnection(
      attemptID: attemptID,
      lease: GatewayTransportConnectionLease()
    )
    await withTaskCancellationHandler {
      if let disconnectedLease {
        await transport.disconnect(lease: disconnectedLease)
      }
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
    attemptID: GatewayClientConnectionAttemptID,
    lease: GatewayTransportConnectionLease
  ) -> GatewayClientConnectionGenerationID {
    let generationID = GatewayClientConnectionGenerationID()
    connectionGenerationID = generationID
    connectedGenerationID = nil
    connectedLease = nil
    connectedProtocolVersion = nil
    connectionLease = lease
    connectionAttemptID = attemptID
    startAttemptIDs.removeAll()
    eventCheckpointRestorations.removeAll()
    terminateEventStreamsForConnectionChange()
    terminateEventStreamAcquisitionWaitersForConnectionChange()
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
    connectedLease = nil
    connectedProtocolVersion = nil
    connectionLease = nil
  }

  func requireCurrentConnectionAttempt(
    _ attemptID: GatewayClientConnectionAttemptID,
    generationID: GatewayClientConnectionGenerationID
  ) throws {
    guard connectionAttemptID == attemptID, connectionGenerationID == generationID else {
      throw supersededOperationFailure()
    }
  }

  func requireConnectedGeneration() throws -> (
    generationID: GatewayClientConnectionGenerationID,
    lease: GatewayTransportConnectionLease
  ) {
    guard
      let connectedGenerationID,
      connectedGenerationID == connectionGenerationID,
      let connectedLease,
      connectedLease == connectionLease
    else {
      throw GatewayFailure(
        code: .notConnected,
        message: "The gateway client is not connected."
      )
    }
    return (connectedGenerationID, connectedLease)
  }

  func requireCurrentConnectedGeneration(
    _ generationID: GatewayClientConnectionGenerationID
  ) throws {
    guard connectionGenerationID == generationID, connectedGenerationID == generationID else {
      throw supersededOperationFailure()
    }
  }

  func validateHandshakeRequest() throws {
    guard configuredMinimumVersion <= configuredMaximumVersion else {
      throw GatewayFailure(
        code: .malformedVersionRange,
        message: "The gateway client protocol version range is malformed."
      )
    }
    guard handshakeRequest.minimumVersion <= handshakeRequest.maximumVersion else {
      throw GatewayFailure(
        code: .incompatibleProtocolVersion,
        message: "The gateway client does not implement a configured protocol version."
      )
    }
  }

  func validateHandshake(_ response: GatewayHandshakeResponse) throws {
    guard response.selectedVersion >= handshakeRequest.minimumVersion,
      response.selectedVersion <= handshakeRequest.maximumVersion,
      response.selectedVersion >= GatewayProtocolVersion.minimumSupported,
      response.selectedVersion <= GatewayProtocolVersion.current
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
    if gatewayInstanceID == response.gatewayInstanceID {
      let key = GatewayRunAcknowledgementKey(
        runID: activeRun.runID,
        invocationID: activeRun.invocationID
      )
      if let acknowledgedSequence = acknowledgedSequences[key],
        activeRun.latestSequence < acknowledgedSequence
      {
        throw GatewayFailure(
          code: .invalidCursor,
          message: "The gateway active-run snapshot regressed below the acknowledged cursor."
        )
      }
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
