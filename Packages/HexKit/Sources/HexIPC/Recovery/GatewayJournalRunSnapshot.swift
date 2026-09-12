import HexCore

/// An immutable durable identity plus a point-in-time high-water. A nil terminal record is not a
/// claim that a worker is still alive. Only resident invocation state can establish that.
public struct GatewayJournalRunSnapshot: Codable, Equatable, Sendable {
  public let runID: AgentRunID
  public let firstEventID: AgentEventID
  public let latestSequence: UInt64
  public let terminalRecord: AgentEventRecord?
  public init(
    runID: AgentRunID, firstEventID: AgentEventID, latestSequence: UInt64,
    terminalRecord: AgentEventRecord?
  ) {
    self.runID = runID
    self.firstEventID = firstEventID
    self.latestSequence = latestSequence
    self.terminalRecord = terminalRecord
  }
}
