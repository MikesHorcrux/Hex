import HexCore

/// Echoes the requested invocation identity. A not-found response does not reveal another
/// generation's identity.
public struct GatewayCancelRunResponse: Codable, Equatable, Sendable {
  public let runID: AgentRunID
  public let invocationID: GatewayRunInvocationID
  public let disposition: GatewayCancelRunDisposition

  public init(
    runID: AgentRunID,
    invocationID: GatewayRunInvocationID,
    disposition: GatewayCancelRunDisposition
  ) {
    self.runID = runID
    self.invocationID = invocationID
    self.disposition = disposition
  }
}
