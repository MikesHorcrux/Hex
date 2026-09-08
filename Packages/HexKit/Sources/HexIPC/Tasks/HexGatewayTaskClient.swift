public protocol HexGatewayTaskClient: Sendable {
  func taskOperation(_ request: GatewayTaskRequest) async throws -> GatewayTaskRequest.Response
}
