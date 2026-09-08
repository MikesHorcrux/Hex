public protocol HexGatewayTaskTransport: Sendable {
  func taskOperation(_ request: GatewayTaskRequest, lease: GatewayTransportConnectionLease)
    async throws -> GatewayTaskRequest.Response
}
