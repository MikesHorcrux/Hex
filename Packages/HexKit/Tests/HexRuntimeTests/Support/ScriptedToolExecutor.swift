import HexCore

actor ScriptedToolExecutor: ToolExecutor {
  private let tools: [ToolDefinition]
  private let discoveryFails: Bool
  private var behaviors: [ToolExecutorBehavior]
  private var authorizationBehaviors: [ToolAuthorizationBehavior]
  private var capturedAuthorizationCalls: [ToolCall] = []
  private var capturedAuthorizationContexts: [ToolExecutionContext] = []
  private var capturedCalls: [ToolCall] = []
  private var capturedContexts: [ToolExecutionContext] = []
  private var capturedDiscoveryCount = 0

  init(
    tools: [ToolDefinition],
    behaviors: [ToolExecutorBehavior] = [],
    authorizationBehaviors: [ToolAuthorizationBehavior] = [],
    discoveryFails: Bool = false
  ) {
    self.tools = tools
    self.behaviors = behaviors
    self.authorizationBehaviors = authorizationBehaviors
    self.discoveryFails = discoveryFails
  }

  func availableTools() async throws -> [ToolDefinition] {
    capturedDiscoveryCount += 1
    if discoveryFails {
      throw ScriptedToolExecutorError.discovery
    }
    return tools
  }

  func authorizationRequest(
    for call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> AuthorizationRequest {
    capturedAuthorizationCalls.append(call)
    capturedAuthorizationContexts.append(context)
    let behavior =
      authorizationBehaviors.isEmpty
      ? .defaultDescription
      : authorizationBehaviors.removeFirst()

    switch behavior {
    case .defaultDescription:
      return AuthorizationRequest(
        runID: context.runID,
        toolCallID: call.id,
        capability: CapabilityID(rawValue: "tool.\(call.name)"),
        operation: "execute",
        explanation: "Authorize execution of the requested tool."
      )
    case .request(let request):
      return request
    case .invalidArguments:
      throw ToolCallValidationError(recovery: "Observe again and use the returned ID.")
    case .throwing:
      throw ScriptedToolExecutorError.authorizationDescription
    case .suspend:
      try await Task.sleep(for: .seconds(60))
      return AuthorizationRequest(
        runID: context.runID,
        toolCallID: call.id,
        capability: CapabilityID(rawValue: "tool.\(call.name)"),
        operation: "execute",
        explanation: "Authorize execution of the requested tool."
      )
    }
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

  func authorizationCalls() -> [ToolCall] {
    capturedAuthorizationCalls
  }

  func authorizationContexts() -> [ToolExecutionContext] {
    capturedAuthorizationContexts
  }

  func contexts() -> [ToolExecutionContext] {
    capturedContexts
  }

  func discoveryCount() -> Int {
    capturedDiscoveryCount
  }
}
