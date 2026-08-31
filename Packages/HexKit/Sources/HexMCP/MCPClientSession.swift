public protocol MCPClientSession: Sendable {
  var serverID: String { get }

  func connect() async throws

  func disconnect() async

  func listTools() async throws -> [MCPRemoteTool]

  func callTool(_ call: MCPRemoteToolCall) async throws -> MCPRemoteToolResult
}
