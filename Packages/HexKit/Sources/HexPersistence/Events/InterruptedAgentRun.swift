import HexCore

/// A privacy-minimal open-time recovery report. It never includes arguments or outputs.
public struct InterruptedAgentRun: Codable, Equatable, Sendable {
  public let runID: AgentRunID
  public let unresolvedToolCallIDs: [ToolCallID]

  public init(
    runID: AgentRunID,
    unresolvedToolCallIDs: [ToolCallID]
  ) {
    self.runID = runID
    self.unresolvedToolCallIDs = unresolvedToolCallIDs
  }
}
