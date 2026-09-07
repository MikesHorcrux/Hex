import Foundation

public struct GatewayHandshakeResponse: Codable, Equatable, Sendable {
  public let sessionID: GatewaySessionID
  public let gatewayInstanceID: GatewayInstanceID
  public let selectedVersion: GatewayProtocolVersion
  public let activeRun: GatewayRunSnapshot?
  public let executableID: UUID?

  public init(
    sessionID: GatewaySessionID,
    gatewayInstanceID: GatewayInstanceID,
    selectedVersion: GatewayProtocolVersion,
    activeRun: GatewayRunSnapshot?
  ) {
    self.init(
      sessionID: sessionID, gatewayInstanceID: gatewayInstanceID, selectedVersion: selectedVersion,
      activeRun: activeRun, executableID: nil)
  }

  public init(
    sessionID: GatewaySessionID,
    gatewayInstanceID: GatewayInstanceID,
    selectedVersion: GatewayProtocolVersion,
    activeRun: GatewayRunSnapshot?,
    executableID: UUID?
  ) {
    self.sessionID = sessionID
    self.gatewayInstanceID = gatewayInstanceID
    self.selectedVersion = selectedVersion
    self.activeRun = activeRun
    self.executableID = executableID
  }
}
