/// A dynamic tool boundary. Each discovery snapshot must contain unique names and perform no side
/// effects. Before execution, the runtime asks this boundary for a deterministic, side-effect-free
/// authorization description. That description must contain only prompt-safe metadata and must not
/// include credentials, file contents, environment values, or other secrets. Host adapters remain
/// responsible for classifying untrusted remote tools such as MCP tools; a remote server must never
/// grant authority to itself.
///
/// Execution must return the supplied call ID, propagate task cancellation, and treat a supplied
/// working directory as an absolute file URL. Authorization is decided outside this boundary.
/// Model-visible failures are returned with `ToolResult.status == .failure`; infrastructure failures
/// may throw. Implementations propagate `CancellationError` without wrapping it.
public protocol ToolExecutor: Sendable {
  func availableTools() async throws -> [ToolDefinition]

  func authorizationRequest(
    for call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> AuthorizationRequest

  func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult
}

extension ToolExecutor {
  /// A conservative fallback for executors that do not expose resource-level policy metadata.
  /// Concrete host-owned tools should override this when they can safely identify a narrower
  /// operation or resource.
  public func authorizationRequest(
    for call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> AuthorizationRequest {
    AuthorizationRequest(
      runID: context.runID,
      toolCallID: call.id,
      capability: CapabilityID(rawValue: "tool.\(call.name)"),
      operation: "execute",
      explanation: "Authorize execution of the requested tool."
    )
  }
}
