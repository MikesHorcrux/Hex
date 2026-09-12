import HexCore

public struct AgentRunResult: Codable, Equatable, Sendable {
  public let runID: AgentRunID
  public let messages: [Message]
  public let turns: [InferenceTurn]
  public let toolCallCount: Int
  public let totalReportedTokens: UInt64

  public init(
    runID: AgentRunID,
    messages: [Message],
    turns: [InferenceTurn],
    toolCallCount: Int,
    totalReportedTokens: UInt64
  ) {
    self.runID = runID
    self.messages = messages
    self.turns = turns
    self.toolCallCount = toolCallCount
    self.totalReportedTokens = totalReportedTokens
  }
}
