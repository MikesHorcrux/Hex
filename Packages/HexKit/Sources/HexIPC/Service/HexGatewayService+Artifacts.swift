import HexCore

extension HexGatewayService {
  public func readArtifact(_ untrusted: GatewayArtifactReadRequest, sessionID: GatewaySessionID)
    async throws -> GatewayArtifactReadResponse
  {
    try Task.checkCancellation()
    try requireSession(sessionID)
    let request = try codec.roundTrip(untrusted)
    try GatewayArtifactReadValidation.request(request)
    guard let artifactReader else {
      throw GatewayFailure(
        code: .artifactUnavailable, message: "The resident has no preserved-output reader.")
    }
    do {
      let chunk = try await artifactReader.read(
        request.reference, offset: request.offset, maximumBytes: request.maximumBytes)
      try Task.checkCancellation()
      try requireSession(sessionID)
      let response = GatewayArtifactReadResponse(chunk: chunk)
      try GatewayArtifactReadValidation.response(response, request: request)
      _ = try codec.encode(
        GatewayXPCResponseEnvelope(operation: .readArtifact, body: codec.encode(response)))
      return try codec.roundTrip(response)
    } catch {
      try Task.checkCancellation()
      try requireSession(sessionID)
      throw GatewayArtifactReadValidation.failure(error)
    }
  }
}
