struct GatewaySessionState: Sendable {
  let clientID: GatewayClientID
  let selectedVersion: GatewayProtocolVersion
}
