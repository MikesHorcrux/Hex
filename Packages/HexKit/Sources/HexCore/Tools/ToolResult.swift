public struct ToolResult: Codable, Equatable, Sendable {
  public let toolCallID: ToolCallID
  public let status: ToolResultStatus
  public let output: JSONValue

  public init(
    toolCallID: ToolCallID,
    status: ToolResultStatus,
    output: JSONValue
  ) {
    self.toolCallID = toolCallID
    self.status = status
    self.output = output
  }
}
