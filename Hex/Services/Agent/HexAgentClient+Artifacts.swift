import HexIPC

extension HexAgentClient {
  func readArtifact(_ request: GatewayArtifactReadRequest) async throws
    -> GatewayArtifactReadResponse
  {
    throw GatewayFailure(
      code: .transportUnavailable,
      message: "This connection cannot read saved output. Connect to Hex Agent and try again.")
  }
}
