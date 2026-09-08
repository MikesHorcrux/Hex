extension HexGatewayClient {
  /// Reads resident lifecycle state through the currently connected gateway session. This method
  /// never opens a connection; callers must connect through this client first.
  public func status() async throws -> GatewayResidentStatus {
    try Task.checkCancellation()
    let connection = try requireConnectedGeneration()
    let controlTransport = try residentControlTransport()

    do {
      let status = try await controlTransport.status(lease: connection.lease)
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      return status
    } catch {
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      invalidateConnectionIfUnavailable(error, generationID: connection.generationID)
      throw error
    }
  }

  /// Pauses scheduled heartbeats through the currently connected gateway session. An interactive
  /// task that is already running is not cancelled by this operation.
  public func pauseHeartbeats() async throws -> GatewayResidentStatus {
    try Task.checkCancellation()
    let connection = try requireConnectedGeneration()
    let controlTransport = try residentControlTransport()

    do {
      let status = try await controlTransport.pauseHeartbeats(lease: connection.lease)
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      return status
    } catch {
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      invalidateConnectionIfUnavailable(error, generationID: connection.generationID)
      throw error
    }
  }

  /// Resumes scheduled heartbeats through the currently connected gateway session.
  public func resumeHeartbeats() async throws -> GatewayResidentStatus {
    try Task.checkCancellation()
    let connection = try requireConnectedGeneration()
    let controlTransport = try residentControlTransport()

    do {
      let status = try await controlTransport.resumeHeartbeats(lease: connection.lease)
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      return status
    } catch {
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      invalidateConnectionIfUnavailable(error, generationID: connection.generationID)
      throw error
    }
  }

  private func residentControlTransport() throws -> any HexGatewayResidentControlTransport {
    guard let controlTransport = transport as? any HexGatewayResidentControlTransport else {
      throw GatewayFailure(
        code: .transportUnavailable,
        message: "The connected gateway transport does not support resident controls."
      )
    }
    return controlTransport
  }
}
