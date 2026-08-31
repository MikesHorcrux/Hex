import HexCore

public struct GatewayCancelRunRequest: Codable, Equatable, Sendable {
  public let runID: AgentRunID

  public init(runID: AgentRunID) {
    self.runID = runID
  }
}
