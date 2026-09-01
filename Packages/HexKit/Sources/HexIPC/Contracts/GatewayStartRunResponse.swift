import HexCore

/// The result of bounded run admission. Exact retries return the same invocation identity while the
/// request remains remembered. After eviction, the same run identifier starts a new invocation with
/// a fresh identity. Busy responses contain no invocation identity.
public struct GatewayStartRunResponse: Codable, Equatable, Sendable {
  public let runID: AgentRunID
  public let disposition: GatewayStartRunDisposition

  public var invocationID: GatewayRunInvocationID? {
    disposition.invocationID
  }

  public init(
    runID: AgentRunID,
    disposition: GatewayStartRunDisposition
  ) {
    self.runID = runID
    self.disposition = disposition
  }
}
