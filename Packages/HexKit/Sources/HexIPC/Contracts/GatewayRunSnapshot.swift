import HexCore

/// A point-in-time description of one exact admitted run invocation.
public struct GatewayRunSnapshot: Codable, Equatable, Sendable {
  public let runID: AgentRunID
  public let invocationID: GatewayRunInvocationID
  public let phase: GatewayRunPhase
  public let latestSequence: UInt64

  public init(
    runID: AgentRunID,
    invocationID: GatewayRunInvocationID,
    phase: GatewayRunPhase,
    latestSequence: UInt64
  ) {
    self.runID = runID
    self.invocationID = invocationID
    self.phase = phase
    self.latestSequence = latestSequence
  }
}
