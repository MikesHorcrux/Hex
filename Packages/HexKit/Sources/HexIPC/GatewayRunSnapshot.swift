import HexCore

public struct GatewayRunSnapshot: Codable, Equatable, Sendable {
  public let runID: AgentRunID
  public let phase: GatewayRunPhase
  public let latestSequence: UInt64

  public init(
    runID: AgentRunID,
    phase: GatewayRunPhase,
    latestSequence: UInt64
  ) {
    self.runID = runID
    self.phase = phase
    self.latestSequence = latestSequence
  }
}
