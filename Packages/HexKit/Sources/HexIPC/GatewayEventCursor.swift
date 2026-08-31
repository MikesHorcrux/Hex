import HexCore

public struct GatewayEventCursor: Codable, Equatable, Sendable {
  public let runID: AgentRunID
  public let sequence: UInt64

  public init(runID: AgentRunID, sequence: UInt64 = 0) {
    self.runID = runID
    self.sequence = sequence
  }
}
