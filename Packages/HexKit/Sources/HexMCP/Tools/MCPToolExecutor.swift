import HexCore

public actor MCPToolExecutor: ToolExecutor {
  private let sessions: [any MCPClientSession]
  private var startedSessions: [any MCPClientSession] = []
  private var startupTask: Task<MCPToolCatalog, any Error>?
  private var shutdownTask: Task<Void, Never>?
  private var definitions: [ToolDefinition] = []
  private var routes: [String: MCPToolRoute] = [:]
  private var isStarted = false
  private var isStopping = false
  private var catalogGeneration = UInt64(0)

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
    guard !isStopping, shutdownTask == nil, catalogGeneration < UInt64.max else {
      throw MCPToolExecutorError.transitionInProgress
    }
    let generation: UInt64
    let task: Task<MCPToolCatalog, any Error>
    if let currentTask = startupTask {
      generation = catalogGeneration
      task = currentTask
    } else {
      catalogGeneration += 1
      generation = catalogGeneration
      let sessions = self.sessions
      let createdTask = Task {
        try await MCPToolExecutorStartup.run(sessions: sessions)
      }
      startupTask = createdTask
      task = createdTask
    }
    do {
      let catalog = try await task.value
      guard catalogGeneration == generation, !isStopping else {
        throw MCPToolExecutorError.transitionInProgress
      }
      if isStarted { return }
      definitions = catalog.definitions
      routes = catalog.routes
      startedSessions = sessions.sorted { $0.serverID < $1.serverID }
      isStarted = true
      startupTask = nil
    } catch {
      if catalogGeneration == generation, !isStarted {
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
    guard catalogGeneration < UInt64.max else {
      throw MCPToolExecutorError.transitionInProgress
    }
    let generation = catalogGeneration
    let catalog = try await MCPToolCatalogBuilder.build(sessions: startedSessions)
    guard catalogGeneration == generation, isStarted, !isStopping else {
      throw MCPToolExecutorError.transitionInProgress
    }
    definitions = catalog.definitions
    routes = catalog.routes
    catalogGeneration += 1
  }

  public func stop() async {
    if let shutdownTask {
      await shutdownTask.value
      return
    }
    isStopping = true
    if catalogGeneration < UInt64.max {
      catalogGeneration += 1
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
    }
    shutdownTask = createdShutdownTask
    await createdShutdownTask.value
    shutdownTask = nil
    isStopping = false
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
    _ = context
    try Task.checkCancellation()
    guard isStarted else {
      throw MCPToolExecutorError.notStarted
    }
    guard let route = routes[call.name] else {
      throw MCPToolExecutorError.unknownTool
    }
    let generation = catalogGeneration
    let remoteResult = try await route.session.callTool(
      MCPRemoteToolCall(name: route.remoteName, arguments: call.arguments)
    )
    try Task.checkCancellation()
    guard catalogGeneration == generation, isStarted, !isStopping else {
      throw MCPToolExecutorError.notStarted
    }
    return try MCPToolResultMapper.map(remoteResult, call: call, route: route)
  }
}
