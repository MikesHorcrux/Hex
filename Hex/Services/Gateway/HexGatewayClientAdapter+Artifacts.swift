import HexIPC

extension HexGatewayClientAdapter {
  func readArtifact(_ request: GatewayArtifactReadRequest) async throws
    -> GatewayArtifactReadResponse
  {
    try await client.readArtifact(request)
  }
}
