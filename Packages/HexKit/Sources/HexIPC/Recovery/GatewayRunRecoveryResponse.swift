import HexCore

public struct GatewayRunRecoveryResponse: Codable, Equatable, Sendable {
  public let gatewayInstanceID: GatewayInstanceID
  public let runID: AgentRunID
  public let disposition: GatewayRunRecoveryDisposition
  public init(
    gatewayInstanceID: GatewayInstanceID, runID: AgentRunID,
    disposition: GatewayRunRecoveryDisposition
  ) {
    self.gatewayInstanceID = gatewayInstanceID
    self.runID = runID
    self.disposition = disposition
  }

  /// Validates injected/read-only service responses. A connected client additionally binds the
  /// instance ID to its handshake; this wrapper does not infer that a connection is current.
  public func validated(for request: GatewayRunRecoveryRequest) throws -> Self {
    try GatewayRunRecoveryValidation.identity(request.runID.rawValue)
    try GatewayRunRecoveryValidation.identity(gatewayInstanceID.rawValue)
    try GatewayRunRecoveryValidation.response(
      self, runID: request.runID, instanceID: gatewayInstanceID)
    let codec = GatewayWireCodec(configuration: .standard)
    _ = try codec.encode(
      GatewayXPCResponseEnvelope(operation: .recoverRun, body: codec.encode(self)))
    return self
  }
}
