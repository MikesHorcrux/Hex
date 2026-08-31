import HexCore

/// The sole mutable owner of gateway sessions, run lifecycle, replay buffers, and live subscribers.
/// It runs in the caller's process and provides no XPC boundary, service installation, persistence
/// across app termination, sandbox escape, or additional filesystem/terminal authority.
public actor HexGatewayService {
  let driver: any HexGatewayRunDriver
  let configuration: GatewayConfiguration
  let codec: GatewayWireCodec
  let gatewayInstanceID: GatewayInstanceID
  var sessions: [GatewaySessionID: GatewaySessionState] = [:]
  var runs: [AgentRunID: GatewayRunState] = [:]
  var completedRunOrder: [AgentRunID] = []
  var activeRunID: AgentRunID?

  public init(
    driver: any HexGatewayRunDriver,
    configuration: GatewayConfiguration = .standard,
    gatewayInstanceID: GatewayInstanceID = GatewayInstanceID()
  ) {
    self.driver = driver
    self.configuration = configuration
    codec = GatewayWireCodec(configuration: configuration)
    self.gatewayInstanceID = gatewayInstanceID
  }
}
