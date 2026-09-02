import HexCore
import Testing

@testable import HexMCP

@Suite("Managed MCP tool executor")
struct MCPManagedToolExecutorTests {
  @Test("Unavailable servers disappear and reconnect at the next discovery")
  func reconnectsAtDiscoveryBoundary() async throws {
    let session = RecoveringSession(serverID: "fixture", isAvailable: false)
    let executor = try MCPManagedToolExecutor(session: session)

    #expect(try await executor.availableTools().isEmpty)
    #expect(await executor.currentState() == .unavailable)

    await session.setAvailable(true)
    #expect(try await executor.availableTools().map(\.name) == ["mcp.fixture.echo"])
    #expect(await executor.currentState() == .ready)
    #expect(await session.connectionCounts() == Counts(connects: 2, disconnects: 0))

    await executor.stop()
    #expect(await session.connectionCounts() == Counts(connects: 2, disconnects: 1))
  }

  @Test("A failed tool call invalidates the server until rediscovery")
  func failedCallInvalidatesServer() async throws {
    let session = RecoveringSession(serverID: "fixture", isAvailable: true)
    let executor = try MCPManagedToolExecutor(session: session)
    #expect(try await executor.availableTools().count == 1)
    await session.setAvailable(false)

    await #expect(throws: FixtureError.unavailable) {
      try await executor.execute(
        ToolCall(name: "mcp.fixture.echo", arguments: [:]),
        in: ToolExecutionContext(runID: AgentRunID())
      )
    }
    #expect(await executor.currentState() == .unavailable)
    #expect(await session.connectionCounts().disconnects == 1)
  }

  private struct Counts: Equatable, Sendable {
    let connects: Int
    let disconnects: Int
  }

  private enum FixtureError: Error, Equatable, Sendable {
    case unavailable
  }

  private actor RecoveringSession: MCPClientSession {
    nonisolated let serverID: String
    private var isAvailable: Bool
    private var connects = 0
    private var disconnects = 0

    init(serverID: String, isAvailable: Bool) {
      self.serverID = serverID
      self.isAvailable = isAvailable
    }

    func connect() async throws {
      connects += 1
      guard isAvailable else { throw FixtureError.unavailable }
    }

    func disconnect() async {
      disconnects += 1
    }

    func listTools() async throws -> [MCPRemoteTool] {
      guard isAvailable else { throw FixtureError.unavailable }
      return [
        MCPRemoteTool(
          name: "echo",
          inputSchema: ["type": .string("object")]
        )
      ]
    }

    func callTool(_ call: MCPRemoteToolCall) async throws -> MCPRemoteToolResult {
      guard isAvailable else { throw FixtureError.unavailable }
      return MCPRemoteToolResult(content: [.text(call.name)], isError: false)
    }

    func setAvailable(_ value: Bool) {
      isAvailable = value
    }

    func connectionCounts() -> Counts {
      Counts(connects: connects, disconnects: disconnects)
    }
  }
}
