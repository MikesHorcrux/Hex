import HexCore

public protocol HostTool: Sendable {
  var definition: ToolDefinition { get }

  func authorizationRequest(
    for call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> AuthorizationRequest

  func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult
}
