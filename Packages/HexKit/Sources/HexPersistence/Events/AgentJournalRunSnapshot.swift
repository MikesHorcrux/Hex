import HexCore

/// Indexed, integrity-checked run metadata. The first event anchors the durable run across opens.
public struct AgentJournalRunSnapshot: Equatable, Sendable {
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
