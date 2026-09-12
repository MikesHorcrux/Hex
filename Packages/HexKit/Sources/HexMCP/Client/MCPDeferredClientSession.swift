import Foundation

/// Retains an enabled optional server even when its local runtime cannot yet be constructed.
///
/// The factory runs at the managed executor's connection boundary, so installation checks still
/// fail closed for that server without preventing core gateway startup. No error description or
/// environment is exposed by this adapter. Each later connection retries the original factory.
public actor MCPDeferredClientSession: MCPClientSession {
  public nonisolated let serverID: String
  private let makeSession: @Sendable () throws -> any MCPClientSession
  private var connection: MCPDeferredClientSessionConnection?
  private var shutdown: (id: UUID, task: Task<Void, Never>)?

  public init(
    serverID: String,
    makeSession: @escaping @Sendable () throws -> any MCPClientSession
  ) throws {
    guard MCPToolCatalogBuilder.isValidServerID(serverID) else {
      throw MCPServerConfigurationError.invalidServerID
    }
    self.serverID = serverID
    self.makeSession = makeSession
  }

  public func connect() async throws {
    try Task.checkCancellation()
    guard connection == nil, shutdown == nil else {
      throw MCPClientSessionError.alreadyConnected
    }
    let session = try makeSession()
    guard session.serverID == serverID else {
      throw MCPClientSessionError.protocolViolation
    }
    let id = UUID()
    // This task owns only the base connection attempt. It never waits on this adapter's
    // shutdown path, so shutdown can drain it without a circular dependency.
    let pendingConnect = Task { try await session.connect() }
    connection = MCPDeferredClientSessionConnection(
      id: id, session: session, pendingConnect: pendingConnect)
    do {
      try await withTaskCancellationHandler {
        try await pendingConnect.value
      } onCancel: {
        pendingConnect.cancel()
      }
      if connection?.id == id { connection?.pendingConnect = nil }
      try Task.checkCancellation()
      guard connection?.id == id else { throw MCPClientSessionError.connectionClosed }
      connection?.isReady = true
    } catch {
      if connection?.id == id {
        connection?.pendingConnect = nil
        await disconnect()
      }
      throw error
    }
  }

  public func disconnect() async {
    if let shutdown {
      await shutdown.task.value
      return
    }
    guard let current = connection else { return }
    connection = nil
    let id = UUID()
    current.pendingConnect?.cancel()
    let task = Task {
      // First interrupt the attempt. A noncooperative implementation can still activate
      // resources later, so retain exclusive ownership until it has finished and clean up
      // that exact session again before any replacement can be admitted.
      await current.session.disconnect()
      if let pendingConnect = current.pendingConnect {
        _ = await pendingConnect.result
        await current.session.disconnect()
      }
      self.finishShutdown(id: id)
    }
    shutdown = (id: id, task: task)
    await task.value
  }

  public func listTools() async throws -> [MCPRemoteTool] {
    let current = try readyConnection()
    let tools = try await current.session.listTools()
    try requireReady(id: current.id)
    return tools
  }

  public func callTool(_ call: MCPRemoteToolCall) async throws -> MCPRemoteToolResult {
    let current = try readyConnection()
    let result = try await current.session.callTool(call)
    // Preserve a same-session result so the runtime can journal it before ending a cancelled run.
    try requireSameReadyConnection(id: current.id)
    return result
  }

  private func readyConnection() throws -> MCPDeferredClientSessionConnection {
    try Task.checkCancellation()
    guard let connection, connection.isReady else { throw MCPClientSessionError.notConnected }
    return connection
  }

  private func requireReady(id: UUID) throws {
    try Task.checkCancellation()
    try requireSameReadyConnection(id: id)
  }

  private func requireSameReadyConnection(id: UUID) throws {
    guard connection?.id == id, connection?.isReady == true else {
      throw MCPClientSessionError.connectionClosed
    }
  }

  private func finishShutdown(id: UUID) {
    guard shutdown?.id == id else { return }
    shutdown = nil
  }
}
