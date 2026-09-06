import HexCore

/// A read-only lookup. Absence is not permission to resubmit an uncertain run.
public struct GatewayRunRecoveryRequest: Codable, Equatable, Sendable {
  public let runID: AgentRunID
  public init(runID: AgentRunID) { self.runID = runID }
}
