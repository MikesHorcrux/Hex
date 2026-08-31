import HexCore

public struct GatewayCancelRunResponse: Codable, Equatable, Sendable {
  public let runID: AgentRunID
  public let disposition: GatewayCancelRunDisposition

  public init(
    runID: AgentRunID,
    disposition: GatewayCancelRunDisposition
  ) {
    self.runID = runID
    self.disposition = disposition
  }
}
