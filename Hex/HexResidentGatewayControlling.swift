/// Control boundary for a gateway that outlives the app window. The resident implementation will
/// be backed by HexIPC; keeping this protocol in the app lets the menu bar ship honest unavailable
/// state until those operations are part of the wire protocol.
nonisolated protocol HexResidentGatewayControlling: Sendable {
  func status() async throws -> HexResidentGatewayStatus
  func setPaused(_ paused: Bool) async throws -> HexResidentGatewayStatus
}
