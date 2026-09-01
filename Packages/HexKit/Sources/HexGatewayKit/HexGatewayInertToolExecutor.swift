import HexCore

struct HexGatewayInertToolExecutor: ToolExecutor, Sendable {
  func availableTools() async throws -> [ToolDefinition] {
    try Task.checkCancellation()
    return []
  }

  func authorizationRequest(
    for call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> AuthorizationRequest {
    _ = call
    _ = context
    try Task.checkCancellation()
    throw HexGatewayCompositionError.toolUnavailable
  }

  func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    _ = call
    _ = context
    try Task.checkCancellation()
    throw HexGatewayCompositionError.toolUnavailable
  }
}
