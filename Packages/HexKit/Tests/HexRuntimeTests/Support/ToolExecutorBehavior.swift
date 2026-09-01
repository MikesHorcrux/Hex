import HexCore

enum ToolExecutorBehavior: Sendable {
  case success
  case failureResult
  case result(ToolResult)
  case mismatchedID
  case throwing
  case suspend
}
