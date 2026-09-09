public protocol HexGatewayProcessSessionClient: Sendable {
  func processSession(_ request: GatewayProcessSessionRequest) async throws
    -> GatewayProcessSessionRequest.Response
}
