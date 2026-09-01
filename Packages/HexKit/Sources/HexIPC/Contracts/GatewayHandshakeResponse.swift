public struct GatewayHandshakeResponse: Codable, Equatable, Sendable {
  public let sessionID: GatewaySessionID
  public let gatewayInstanceID: GatewayInstanceID
  public let selectedVersion: GatewayProtocolVersion
  public let activeRun: GatewayRunSnapshot?

  public init(
    sessionID: GatewaySessionID,
    gatewayInstanceID: GatewayInstanceID,
    selectedVersion: GatewayProtocolVersion,
    activeRun: GatewayRunSnapshot?
  ) {
    self.sessionID = sessionID
    self.gatewayInstanceID = gatewayInstanceID
    self.selectedVersion = selectedVersion
    self.activeRun = activeRun
  }
}
