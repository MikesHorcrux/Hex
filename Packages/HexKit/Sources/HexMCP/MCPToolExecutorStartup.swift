enum MCPToolExecutorStartup {
  static func run(
    sessions: [any MCPClientSession]
  ) async throws -> MCPToolCatalog {
    var connected: [any MCPClientSession] = []
    do {
      for session in sessions.sorted(by: { $0.serverID < $1.serverID }) {
        try Task.checkCancellation()
        try await session.connect()
        connected.append(session)
      }
      try Task.checkCancellation()
      return try await MCPToolCatalogBuilder.build(sessions: connected)
    } catch {
      for session in connected.reversed() {
        await session.disconnect()
      }
      throw error
    }
  }
}
