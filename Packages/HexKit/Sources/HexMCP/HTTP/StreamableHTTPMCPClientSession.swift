public struct StreamableHTTPMCPClientSession: MCPClientSession, Sendable {
  public let serverID: String
  private let session: LocalMCPClientSession

  public init(
    configuration: MCPStreamableHTTPServerConfiguration,
    headerProvider: any MCPHTTPHeaderProvider = MCPEmptyHTTPHeaderProvider()
  ) {
    serverID = configuration.serverID
    session = LocalMCPClientSession(
      configuration: MCPClientSessionConfiguration(configuration),
      connection: MCPStreamableHTTPJSONRPCConnection(
        configuration: configuration,
        headerProvider: headerProvider
      )
    )
  }

  init(
    configuration: MCPStreamableHTTPServerConfiguration,
    headerProvider: any MCPHTTPHeaderProvider,
    transport: any MCPHTTPTransport
  ) {
    serverID = configuration.serverID
    session = LocalMCPClientSession(
      configuration: MCPClientSessionConfiguration(configuration),
      connection: MCPStreamableHTTPJSONRPCConnection(
        configuration: configuration,
        headerProvider: headerProvider,
        transport: transport
      )
    )
  }

  public var initialization: MCPSessionInitialization? {
    get async { await session.initialization }
  }

  public func connect() async throws {
    try await session.connect()
  }

  public func disconnect() async {
    await session.disconnect()
  }

  public func listTools() async throws -> [MCPRemoteTool] {
    try await session.listTools()
  }

  public func callTool(_ call: MCPRemoteToolCall) async throws -> MCPRemoteToolResult {
    try await session.callTool(call)
  }
}
