/// A dynamic tool boundary. Each discovery snapshot must contain unique names and perform no side
/// effects. Execution must return the supplied call ID, propagate task cancellation, and treat a
/// supplied working directory as an absolute file URL. Authorization is performed outside this
/// boundary. Model-visible failures are returned with `ToolResult.status == .failure`;
/// infrastructure failures may throw. Implementations propagate `CancellationError` without
/// wrapping it.
public protocol ToolExecutor: Sendable {
  func availableTools() async throws -> [ToolDefinition]

  func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult
}
