extension HexGatewayClient {
  /// Local connection validity, not a remote health probe. A transport failure invalidates this
  /// state before it reaches the caller, so higher layers cannot reuse a stale cached handshake.
  public var isConnected: Bool {
    connectedGenerationID == connectionGenerationID
      && connectedLease != nil
      && connectedLease == connectionLease
  }

  func invalidateConnectionIfUnavailable(
    _ error: any Error,
    generationID: GatewayClientConnectionGenerationID
  ) {
    guard let failure = error as? GatewayFailure,
      connectionGenerationID == generationID,
      connectedGenerationID == generationID
    else {
      return
    }
    switch failure.code {
    case .notConnected, .staleSession, .transportUnavailable, .disconnected,
      .producerEndedWithoutTerminalEvent:
      break
    default:
      return
    }

    connectedGenerationID = nil
    connectedLease = nil
    startAttemptIDs.removeAll()
    terminateEventStreamsForConnectionChange(failure: failure)
    terminateEventStreamAcquisitionWaitersForConnectionChange(failure: failure)
    // Keep the physical lease so an explicit disconnect still releases it. The next handshake
    // replaces the transport connection. Never cancel or restart a run as part of this recovery,
    // and keep acknowledgement history until a handshake proves the gateway instance changed.
  }
}
