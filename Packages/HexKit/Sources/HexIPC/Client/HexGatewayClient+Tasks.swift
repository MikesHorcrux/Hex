extension HexGatewayClient: HexGatewayTaskClient {
  public func taskOperation(_ request: GatewayTaskRequest) async throws
    -> GatewayTaskRequest.Response
  {
    try Task.checkCancellation()
    let connection = try requireConnectedGeneration()
    guard let transport = transport as? any HexGatewayTaskTransport else {
      throw GatewayFailure(code: .recoveryUnavailable, message: "Durable tasks are unavailable.")
    }
    do {
      let response = try await transport.taskOperation(request, lease: connection.lease)
      try requireCurrentConnectedGeneration(connection.generationID)
      return try GatewayWireCodec(configuration: configuration).roundTrip(response)
    } catch {
      try requireCurrentConnectedGeneration(connection.generationID)
      invalidateConnectionIfUnavailable(error, generationID: connection.generationID)
      throw error
    }
  }
}
