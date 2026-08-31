public struct GatewayHandshakeRequest: Codable, Equatable, Sendable {
  public let clientID: GatewayClientID
  public let minimumVersion: GatewayProtocolVersion
  public let maximumVersion: GatewayProtocolVersion

  public init(
    clientID: GatewayClientID,
    minimumVersion: GatewayProtocolVersion = .minimumSupported,
    maximumVersion: GatewayProtocolVersion = .current
  ) {
    self.clientID = clientID
    self.minimumVersion = minimumVersion
    self.maximumVersion = maximumVersion
  }
}
