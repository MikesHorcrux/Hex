extension HexGatewayClient {
  public func toolServerHealth() async throws -> GatewayToolServerHealth {
    try Task.checkCancellation()
    let connection = try requireConnectedGeneration()
    let control = try toolServerControlTransport()
    do {
      let response = try await control.toolServerHealth(lease: connection.lease)
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      return try GatewayWireCodec(configuration: configuration).roundTrip(response).validated()
    } catch {
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      invalidateConnectionIfUnavailable(error, generationID: connection.generationID)
      throw error
    }
  }

  public func refreshToolServer(_ request: GatewayToolServerRequest) async throws
    -> GatewayToolServerStatus
  {
    try Task.checkCancellation()
    let request = try request.validated()
    let connection = try requireConnectedGeneration()
    let control = try toolServerControlTransport()
    do {
      let response = try await control.refreshToolServer(request, lease: connection.lease)
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      return try GatewayWireCodec(configuration: configuration).roundTrip(response).validated(
        for: request)
    } catch {
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      invalidateConnectionIfUnavailable(error, generationID: connection.generationID)
      throw error
    }
  }

  private func toolServerControlTransport() throws -> any HexGatewayToolServerControlTransport {
    guard let connectedProtocolVersion,
      connectedProtocolVersion >= GatewayProtocolVersion(major: 1, minor: 13)
    else {
      throw GatewayFailure(
        code: .transportUnavailable,
        message: "Update the resident agent to inspect and reconnect individual tool servers.")
    }
    guard let control = transport as? any HexGatewayToolServerControlTransport else {
      throw GatewayFailure(
        code: .transportUnavailable, message: "Tool server controls are unavailable.")
    }
    return control
  }
}
