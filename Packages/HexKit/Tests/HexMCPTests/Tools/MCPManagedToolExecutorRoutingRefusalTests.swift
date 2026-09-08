import HexCore
import Testing

@testable import HexMCP

@Suite("Managed MCP local routing refusals preserve healthy sessions")
struct MCPManagedToolExecutorRoutingRefusalTests {
  @Test(
    "A removed tool is refused locally while its replacement remains callable without reconnect")
  func removedToolDoesNotInvalidateRefreshedServer() async throws {
    let session = ChangingCatalogSession()
    let executor = try MCPManagedToolExecutor(session: session)
    let context = ToolExecutionContext(runID: AgentRunID())
    #expect(try await executor.availableTools().map(\.name) == ["mcp_7_fixture_original"])
    await session.replaceCatalog()
    try await executor.refreshCatalog()

    await #expect(throws: MCPToolExecutorError.unknownTool) {
      try await executor.execute(
        ToolCall(name: "mcp_7_fixture_original", arguments: [:]), in: context)
    }
    #expect(await session.calls.isEmpty)
    #expect(await executor.currentState() == .ready)
    #expect(try await executor.availableTools().map(\.name) == ["mcp_7_fixture_replacement"])
    #expect(await session.connects == 1)
    #expect(await session.disconnects == 0)
    #expect(await session.catalogReads == 2)

    let replacement = ToolCall(name: "mcp_7_fixture_replacement", arguments: ["value": .integer(7)])
    let receipt = try await executor.execute(replacement, in: context)
    #expect(receipt.toolCallID == replacement.id)
    #expect(receipt.status == .success)
    #expect(receipt.content == [.text("Replacement receipt")])
    #expect(
      await session.calls == [
        MCPRemoteToolCall(name: "replacement", arguments: replacement.arguments)
      ])
    #expect(await executor.currentState() == .ready)
    #expect(await session.connects == 1)
    #expect(await session.disconnects == 0)
    await executor.stop()
  }

  @Test("The same error after remote dispatch still invalidates an uncertain session")
  func remoteUnknownToolErrorIsNotMistakenForLocalRefusal() async throws {
    let session = ChangingCatalogSession(throwRemoteUnknownTool: true)
    let executor = try MCPManagedToolExecutor(session: session)
    #expect(try await executor.availableTools().count == 1)
    let call = ToolCall(name: "mcp_7_fixture_original", arguments: [:])
    await #expect(throws: MCPToolExecutorError.unknownTool) {
      try await executor.execute(call, in: ToolExecutionContext(runID: AgentRunID()))
    }
    #expect(await session.calls == [MCPRemoteToolCall(name: "original", arguments: [:])])
    #expect(await executor.currentState() == .unavailable)
    #expect(await session.disconnects == 1)
    #expect(await session.connects == 1)
    #expect(try await executor.availableTools().isEmpty)
    await executor.stop()
  }

  private actor ChangingCatalogSession: MCPClientSession {
    nonisolated let serverID = "fixture"
    let throwRemoteUnknownTool: Bool
    private var remoteName = "original"
    private(set) var connects = 0
    private(set) var disconnects = 0
    private(set) var catalogReads = 0
    private(set) var calls: [MCPRemoteToolCall] = []

    init(throwRemoteUnknownTool: Bool = false) {
      self.throwRemoteUnknownTool = throwRemoteUnknownTool
    }
    func connect() async throws { connects += 1 }
    func disconnect() async { disconnects += 1 }
    func replaceCatalog() { remoteName = "replacement" }
    func listTools() async throws -> [MCPRemoteTool] {
      catalogReads += 1
      return [MCPRemoteTool(name: remoteName, inputSchema: ["type": .string("object")])]
    }
    func callTool(_ call: MCPRemoteToolCall) async throws -> MCPRemoteToolResult {
      calls.append(call)
      if throwRemoteUnknownTool { throw MCPToolExecutorError.unknownTool }
      return MCPRemoteToolResult(content: [.text("Replacement receipt")], isError: false)
    }
  }
}
