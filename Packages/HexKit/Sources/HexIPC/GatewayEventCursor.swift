import HexCore

/// An exclusive replay position for one exact `(runID, invocationID)` generation.
public struct GatewayEventCursor: Codable, Equatable, Sendable {
  public let runID: AgentRunID
  public let invocationID: GatewayRunInvocationID
  public let sequence: UInt64

  public init(
    runID: AgentRunID,
    invocationID: GatewayRunInvocationID,
    sequence: UInt64 = 0
  ) {
    self.runID = runID
    self.invocationID = invocationID
    self.sequence = sequence
  }
}
