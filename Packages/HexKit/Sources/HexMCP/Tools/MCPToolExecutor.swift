import Foundation
import HexCore

public actor MCPToolExecutor: ToolExecutor {
  private let sessions: [any MCPClientSession]
  private var startedSessions: [any MCPClientSession] = []
  private var startupTask: Task<MCPToolCatalog, any Error>?
  private var shutdown: (id: UUID, task: Task<Void, Never>)?
  private var definitions: [ToolDefinition] = []
  private var routes: [String: MCPToolRoute] = [:]
  private var isStarted = false
  private var isStopping = false
  // A list refresh changes future routes, not the ownership of calls already dispatched.
  // Only a session lifecycle change invalidates their eventual receipts.
  private var sessionGeneration = UInt64(0)
  private var catalogRevision = UInt64(0)

  public init(sessions: [any MCPClientSession]) throws {
    guard !sessions.isEmpty, sessions.count <= 16 else {
      throw MCPToolExecutorError.invalidSession
    }
    let identifiers = sessions.map(\.serverID)
    guard
      identifiers.allSatisfy(MCPToolCatalogBuilder.isValidServerID),
      Set(identifiers).count == identifiers.count
    else {
      throw MCPToolExecutorError.invalidSession
    }
    self.sessions = sessions
  }

  public func start() async throws {
    try Task.checkCancellation()
    guard !isStarted else { return }
    guard !isStopping, shutdown == nil, sessionGeneration < UInt64.max else {
      throw MCPToolExecutorError.transitionInProgress
    }
    let generation: UInt64
    let task: Task<MCPToolCatalog, any Error>
    if let currentTask = startupTask {
      generation = sessionGeneration
      task = currentTask
    } else {
      sessionGeneration += 1
      generation = sessionGeneration
      let sessions = self.sessions
      let createdTask = Task {
        try await MCPToolExecutorStartup.run(sessions: sessions)
      }
      startupTask = createdTask
      task = createdTask
    }
    do {
      let catalog = try await task.value
      guard sessionGeneration == generation, !isStopping else {
        throw MCPToolExecutorError.transitionInProgress
      }
      if isStarted { return }
      definitions = catalog.definitions
      routes = catalog.routes
      catalogRevision = 0
      startedSessions = sessions.sorted { $0.serverID < $1.serverID }
      isStarted = true
      startupTask = nil
    } catch {
      if sessionGeneration == generation, !isStarted {
        startupTask = nil
      }
      throw error
    }
  }

  public func refreshCatalog() async throws {
    try Task.checkCancellation()
    guard isStarted, !isStopping else {
      throw MCPToolExecutorError.notStarted
    }
    guard catalogRevision < UInt64.max else {
      throw MCPToolExecutorError.transitionInProgress
    }
    let generation = sessionGeneration
    let revision = catalogRevision
    let catalog = try await MCPToolCatalogBuilder.build(sessions: startedSessions)
    guard sessionGeneration == generation, catalogRevision == revision, isStarted, !isStopping
    else {
      throw MCPToolExecutorError.transitionInProgress
    }
    definitions = catalog.definitions
    routes = catalog.routes
    catalogRevision += 1
  }

  public func stop() async {
    let shutdown = beginShutdown()
    await shutdown.task.value
  }

  /// Invalidates the catalog and requests cleanup without waiting for a slow server to exit.
  ///
  /// The cleanup task owns the final state transition, so a later discovery either observes an
  /// active shutdown or a fully restartable executor.
  func requestStop() {
    _ = beginShutdown()
  }

  private func beginShutdown() -> (id: UUID, task: Task<Void, Never>) {
    if let shutdown { return shutdown }
    isStopping = true
    if sessionGeneration < UInt64.max {
      sessionGeneration += 1
    }
    let pendingStartup = startupTask
    let connectedSessions = startedSessions
    startupTask = nil
    pendingStartup?.cancel()
    startedSessions = []
    definitions = []
    routes = [:]
    isStarted = false
    let allSessions = sessions.sorted { $0.serverID < $1.serverID }
    let shutdownID = UUID()
    let createdShutdownTask = Task {
      if let pendingStartup {
        if case .success = await pendingStartup.result {
          for session in allSessions.reversed() {
            await session.disconnect()
          }
        }
      } else {
        for session in connectedSessions.reversed() {
          await session.disconnect()
        }
      }
      self.finishShutdown(id: shutdownID)
    }
    shutdown = (id: shutdownID, task: createdShutdownTask)
    return (id: shutdownID, task: createdShutdownTask)
  }

  public func availableTools() async throws -> [ToolDefinition] {
    try Task.checkCancellation()
    return definitions
  }

  public func authorizationRequest(
    for call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> AuthorizationRequest {
    try Task.checkCancellation()
    guard isStarted else {
      throw MCPToolExecutorError.notStarted
    }
    guard let route = routes[call.name] else {
      throw MCPToolExecutorError.unknownTool
    }
    return AuthorizationRequest(
      runID: context.runID,
      toolCallID: call.id,
      capability: CapabilityID(rawValue: call.name),
      operation: "call",
      resource: "mcp://\(route.serverID)/\(route.remoteName)",
      details: [
        "server": .string(route.serverID),
        "tool": .string(route.remoteName),
      ],
      explanation: "Authorize the selected local MCP server tool."
    )
  }

  public func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    try await execute(call, in: context, willDispatch: {})
  }

  /// Host-only evidence of crossing the session boundary, distinct from a local routing refusal.
  func execute(
    _ call: ToolCall, in context: ToolExecutionContext,
    willDispatch: @Sendable () -> Void
  ) async throws -> ToolResult {
    _ = context
    try Task.checkCancellation()
    guard isStarted else {
      throw MCPToolExecutorError.notStarted
    }
    guard let route = routes[call.name] else {
      throw MCPToolExecutorError.unknownTool
    }
    let generation = sessionGeneration
    willDispatch()
    let remoteResult = try await route.session.callTool(
      MCPRemoteToolCall(name: route.remoteName, arguments: call.arguments)
    )
    // A returned receipt may describe completed side effects. Keep validating its session and
    // payload, but let the runtime persist that known outcome before it honors cancellation.
    guard sessionGeneration == generation, isStarted, !isStopping else {
      throw MCPToolExecutorError.notStarted
    }
    return try MCPToolResultMapper.map(remoteResult, call: call, route: route)
  }

  private func finishShutdown(id: UUID) {
    guard shutdown?.id == id else { return }
    shutdown = nil
    isStopping = false
  }
}
