import HexCore
import HexGatewayKit

actor GatewayTestToolExecutor: ToolExecutor {
  private let tool: ToolDefinition?
  private var capturedContexts: [ToolExecutionContext] = []

  init(tool: ToolDefinition? = nil) {
    self.tool = tool
  }

  func availableTools() async throws -> [ToolDefinition] {
    try Task.checkCancellation()
    if let tool {
      return [tool]
    }
    return []
  }

  func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    try Task.checkCancellation()
    guard call.name == tool?.name else {
      throw HexGatewayCompositionError.toolUnavailable
    }
    capturedContexts.append(context)
    return ToolResult(
      toolCallID: call.id,
      status: .success,
      output: .string("recorded")
    )
  }

  func contexts() -> [ToolExecutionContext] {
    capturedContexts
  }
}
