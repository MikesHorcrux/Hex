import HexCore

/// A durable journal link, not a copied transcript or a live invocation identity.
public struct GatewayHeartbeatRunJournalIdentity: Codable, Equatable, Sendable {
  public let runID: AgentRunID
  public let firstEventID: AgentEventID
  public let terminalSequence: UInt64

  public init(runID: AgentRunID, firstEventID: AgentEventID, terminalSequence: UInt64) {
    self.runID = runID
    self.firstEventID = firstEventID
    self.terminalSequence = terminalSequence
  }

  public func validated() throws -> Self {
    try GatewayRunRecoveryValidation.identity(runID.rawValue)
    try GatewayRunRecoveryValidation.identity(firstEventID.rawValue)
    guard terminalSequence >= 2, terminalSequence <= UInt64(Int64.max) else {
      throw GatewayFailure(
        code: .invalidCursor, message: "The scheduled run journal link is invalid.")
    }
    return self
  }
}
