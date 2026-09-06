extension HexGatewayClient {
  public func readArtifact(_ request: GatewayArtifactReadRequest) async throws
    -> GatewayArtifactReadResponse
  {
    try Task.checkCancellation()
    try GatewayArtifactReadValidation.request(request)
    let connection = try requireConnectedGeneration()
    guard let artifacts = transport as? any HexGatewayArtifactReadTransport else {
      throw GatewayFailure(
        code: .artifactUnavailable, message: "This connection cannot read preserved output.")
    }
    do {
      let response = try await artifacts.readArtifact(request, lease: connection.lease)
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      let codec = GatewayWireCodec(configuration: configuration)
      let validated = try codec.roundTrip(response)
      try GatewayArtifactReadValidation.response(validated, request: request)
      _ = try codec.encode(
        GatewayXPCResponseEnvelope(operation: .readArtifact, body: codec.encode(validated)))
      return validated
    } catch {
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      invalidateConnectionIfUnavailable(error, generationID: connection.generationID)
      throw GatewayArtifactReadValidation.failure(error)
    }
  }
}
