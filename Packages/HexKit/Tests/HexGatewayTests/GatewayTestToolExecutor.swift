import HexCore
import HexGatewayKit

struct GatewayTestToolExecutor: ToolExecutor, Sendable {
  func availableTools() async throws -> [ToolDefinition] {
    try Task.checkCancellation()
    return []
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
