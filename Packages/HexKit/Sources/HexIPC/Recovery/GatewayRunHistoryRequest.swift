import HexCore

/// Bounded read of one anchored, fixed-prefix journal snapshot. afterSequence is exclusive.
public struct GatewayRunHistoryRequest: Codable, Equatable, Sendable {
  public let runID: AgentRunID
  public let firstEventID: AgentEventID
  public let afterSequence: UInt64
  public let throughSequence: UInt64
  public let limit: Int
  public init(
    runID: AgentRunID, firstEventID: AgentEventID, afterSequence: UInt64, throughSequence: UInt64,
    limit: Int = 32
  ) {
    self.runID = runID
    self.firstEventID = firstEventID
    self.afterSequence = afterSequence
    self.throughSequence = throughSequence
    self.limit = limit
  }
}
