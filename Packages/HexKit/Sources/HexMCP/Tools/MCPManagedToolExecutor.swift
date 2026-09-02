import HexCore

/// Keeps one MCP server optional at the runtime boundary.
///
/// A missing or stopped server removes only its own tools. The next runtime discovery boundary
/// retries the connection, allowing an always-on gateway to recover after Xcode or another local
/// server starts later.
public actor MCPManagedToolExecutor: ToolExecutor {
  public nonisolated let serverID: String

  private let executor: MCPToolExecutor
  private var state = MCPManagedToolExecutorState.disconnected

  public init(session: any MCPClientSession) throws {
    serverID = session.serverID
    executor = try MCPToolExecutor(sessions: [session])
  }

  public func availableTools() async throws -> [ToolDefinition] {
    try Task.checkCancellation()
    guard try await ensureStarted() else { return [] }
    do {
      return try await executor.availableTools()
    } catch is CancellationError {
      await invalidate(nextState: .disconnected)
      throw CancellationError()
    } catch {
      await invalidate(nextState: .unavailable)
      return []
    }
  }

  public func authorizationRequest(
    for call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> AuthorizationRequest {
    try Task.checkCancellation()
    guard state == .ready else {
      throw MCPToolExecutorError.notStarted
    }
    return try await executor.authorizationRequest(for: call, in: context)
  }

  public func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    try Task.checkCancellation()
    guard state == .ready else {
      throw MCPToolExecutorError.notStarted
    }
    do {
      return try await executor.execute(call, in: context)
    } catch is CancellationError {
      await invalidate(nextState: .disconnected)
      throw CancellationError()
    } catch {
      await invalidate(nextState: .unavailable)
      throw error
    }
  }

  public func refreshCatalog() async throws {
    try Task.checkCancellation()
    guard state == .ready else {
      throw MCPToolExecutorError.notStarted
    }
    do {
      try await executor.refreshCatalog()
    } catch {
      await invalidate(nextState: .unavailable)
      throw error
    }
  }

  public func stop() async {
    await invalidate(nextState: .disconnected)
  }

  public func currentState() -> MCPManagedToolExecutorState {
    state
  }

  private func ensureStarted() async throws -> Bool {
    if state == .ready { return true }
    state = .connecting
    do {
      try await executor.start()
      state = .ready
      return true
    } catch is CancellationError {
      await invalidate(nextState: .disconnected)
      throw CancellationError()
    } catch {
      await invalidate(nextState: .unavailable)
      return false
    }
  }

  private func invalidate(nextState: MCPManagedToolExecutorState) async {
    await executor.stop()
    state = nextState
  }
}
