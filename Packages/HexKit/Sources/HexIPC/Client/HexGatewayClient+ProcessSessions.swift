import HexCore

extension HexGatewayClient: HexGatewayProcessSessionClient {
  public func processSession(_ request: GatewayProcessSessionRequest) async throws
    -> GatewayProcessSessionResponse
  {
    let connection = try requireConnectedGeneration()
    guard let transport = transport as? any HexGatewayProcessSessionTransport else {
      throw GatewayFailure(code: .recoveryUnavailable, message: "Process sessions are unavailable.")
    }
    do {
      let response = try await transport.processSession(request, lease: connection.lease)
      try requireCurrentConnectedGeneration(connection.generationID)
      return try GatewayWireCodec(configuration: configuration).roundTrip(response)
    } catch {
      try requireCurrentConnectedGeneration(connection.generationID)
      invalidateConnectionIfUnavailable(error, generationID: connection.generationID)
      throw error
    }
  }
}
