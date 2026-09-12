public struct AgentTaskEffect: Sendable {
  public let runID: AgentRunID
  public let callID: ToolCallID
  public let result: ToolResult?
  public init(runID: AgentRunID, callID: ToolCallID, result: ToolResult?) {
    self.runID = runID
    self.callID = callID
    self.result = result
  }
}
