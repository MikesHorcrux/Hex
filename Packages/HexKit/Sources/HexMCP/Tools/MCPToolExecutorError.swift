public enum MCPToolExecutorError: Error, Equatable, Sendable {
  case invalidSession
  case invalidToolDefinition
  case duplicateTool
  case notStarted
  case unknownTool
  case invalidToolResult
  case transitionInProgress
}
