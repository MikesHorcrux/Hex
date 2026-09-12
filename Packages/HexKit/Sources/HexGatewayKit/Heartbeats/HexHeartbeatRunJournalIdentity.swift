import HexCore

/// An exact durable output link, never a manufactured live invocation or a copied transcript.
public struct HexHeartbeatRunJournalIdentity: Codable, Equatable, Sendable {
  public let runID: AgentRunID
  public let firstEventID: AgentEventID
  public let terminalSequence: UInt64

  public init(runID: AgentRunID, firstEventID: AgentEventID, terminalSequence: UInt64) {
    self.runID = runID
    self.firstEventID = firstEventID
    self.terminalSequence = terminalSequence
  }
}
