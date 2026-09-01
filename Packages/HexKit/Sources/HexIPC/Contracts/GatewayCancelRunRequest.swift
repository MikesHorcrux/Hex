import HexCore

/// Cancellation targets one exact run generation; a reused run identifier alone is insufficient.
public struct GatewayCancelRunRequest: Codable, Equatable, Sendable {
  public let runID: AgentRunID
  public let invocationID: GatewayRunInvocationID

  public init(runID: AgentRunID, invocationID: GatewayRunInvocationID) {
    self.runID = runID
    self.invocationID = invocationID
  }
}
