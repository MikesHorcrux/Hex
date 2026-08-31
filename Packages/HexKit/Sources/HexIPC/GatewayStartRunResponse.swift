import HexCore

public struct GatewayStartRunResponse: Codable, Equatable, Sendable {
  public let runID: AgentRunID
  public let disposition: GatewayStartRunDisposition

  public init(
    runID: AgentRunID,
    disposition: GatewayStartRunDisposition
  ) {
    self.runID = runID
    self.disposition = disposition
  }
}
