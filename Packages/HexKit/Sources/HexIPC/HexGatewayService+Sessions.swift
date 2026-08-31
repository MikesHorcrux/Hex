import HexCore

extension HexGatewayService {
  public func handshake(
    _ untrustedRequest: GatewayHandshakeRequest
  ) throws -> GatewayHandshakeResponse {
    let request = try codec.roundTrip(untrustedRequest)
    guard request.minimumVersion <= request.maximumVersion else {
      throw GatewayFailure(
        code: .malformedVersionRange,
        message: "The gateway protocol version range is malformed."
      )
    }

    let lowerBound =
      request.minimumVersion > GatewayProtocolVersion.minimumSupported
      ? request.minimumVersion
      : GatewayProtocolVersion.minimumSupported
    let upperBound =
      request.maximumVersion < GatewayProtocolVersion.current
      ? request.maximumVersion
      : GatewayProtocolVersion.current

    guard lowerBound <= upperBound else {
      throw GatewayFailure(
        code: .incompatibleProtocolVersion,
        message: "The client and gateway do not share a supported protocol version."
      )
    }

    guard sessions.count < configuration.maximumSessions else {
      throw GatewayFailure(
        code: .capacityExceeded,
        message: "The gateway has reached its configured active-session limit.",
        isRetryable: true
      )
    }

    let sessionID = GatewaySessionID()
    let response = try codec.roundTrip(
      GatewayHandshakeResponse(
        sessionID: sessionID,
        gatewayInstanceID: gatewayInstanceID,
        selectedVersion: upperBound,
        activeRun: activeRunSnapshot()
      )
    )
    sessions[sessionID] = GatewaySessionState(
      clientID: request.clientID,
      selectedVersion: upperBound
    )
    return response
  }

  public func disconnect(sessionID untrustedSessionID: GatewaySessionID) {
    guard let sessionID = try? codec.roundTrip(untrustedSessionID) else {
      return
    }
    guard sessions.removeValue(forKey: sessionID) != nil else {
      return
    }

    let failure = GatewayFailure(
      code: .disconnected,
      message: "The gateway session disconnected.",
      isRetryable: true
    )

    let runIDs = Array(runs.keys)
    for runID in runIDs {
      guard var state = runs[runID] else {
        continue
      }

      let disconnectedSubscriberIDs = state.subscribers.compactMap { entry in
        entry.value.sessionID == sessionID ? entry.key : nil
      }
      for subscriberID in disconnectedSubscriberIDs {
        state.subscribers.removeValue(forKey: subscriberID)?.continuation.finish(
          throwing: failure
        )
      }
      runs[runID] = state
    }
  }

  func requireSession(_ sessionID: GatewaySessionID) throws {
    guard sessions[sessionID] != nil else {
      throw GatewayFailure(
        code: .staleSession,
        message: "The gateway session is missing or no longer active.",
        isRetryable: true
      )
    }
  }

  private func activeRunSnapshot() -> GatewayRunSnapshot? {
    guard let activeRunID, let state = runs[activeRunID] else {
      return nil
    }
    return GatewayRunSnapshot(
      runID: activeRunID,
      phase: state.phase,
      latestSequence: state.latestSequence
    )
  }
}
