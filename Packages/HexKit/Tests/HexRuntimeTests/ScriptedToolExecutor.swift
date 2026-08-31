import HexCore

actor ScriptedToolExecutor: ToolExecutor {
  private let tools: [ToolDefinition]
  private let discoveryFails: Bool
  private var behaviors: [ToolExecutorBehavior]
  private var capturedCalls: [ToolCall] = []
  private var capturedContexts: [ToolExecutionContext] = []
  private var capturedDiscoveryCount = 0

  init(
    tools: [ToolDefinition],
    behaviors: [ToolExecutorBehavior] = [],
    discoveryFails: Bool = false
  ) {
    self.tools = tools
    self.behaviors = behaviors
    self.discoveryFails = discoveryFails
  }

  func availableTools() async throws -> [ToolDefinition] {
    capturedDiscoveryCount += 1
    if discoveryFails {
      throw ScriptedToolExecutorError.discovery
    }
    return tools
  }

  func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    capturedCalls.append(call)
    capturedContexts.append(context)
    let behavior = behaviors.isEmpty ? .success : behaviors.removeFirst()
    switch behavior {
    case .success:
      return ToolResult(
        toolCallID: call.id,
        status: .success,
        output: .string("result:\(call.name)")
      )
    case .failureResult:
      return ToolResult(
        toolCallID: call.id,
        status: .failure,
        output: .string("tool_failed")
      )
    case .result(let result):
      return result
    case .mismatchedID:
      return ToolResult(toolCallID: ToolCallID(), status: .success, output: .null)
    case .throwing:
      throw ScriptedToolExecutorError.execution
    case .suspend:
      try await Task.sleep(for: .seconds(60))
      return ToolResult(toolCallID: call.id, status: .success, output: .null)
    }
  }

  func calls() -> [ToolCall] {
    capturedCalls
  }

  func contexts() -> [ToolExecutionContext] {
    capturedContexts
  }

  func discoveryCount() -> Int {
    capturedDiscoveryCount
  }
}
