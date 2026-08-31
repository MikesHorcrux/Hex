public struct GatewayConnectionResult: Equatable, Sendable {
  public let response: GatewayHandshakeResponse
  public let previousGatewayInstanceID: GatewayInstanceID?

  public init(
    response: GatewayHandshakeResponse,
    previousGatewayInstanceID: GatewayInstanceID?
  ) {
    self.response = response
    self.previousGatewayInstanceID = previousGatewayInstanceID
  }

  public var didDetectGatewayRestart: Bool {
    guard let previousGatewayInstanceID else {
      return false
    }
    return previousGatewayInstanceID != response.gatewayInstanceID
  }
}
