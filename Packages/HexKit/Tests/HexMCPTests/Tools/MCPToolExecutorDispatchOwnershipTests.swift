import HexCore
import Testing

@testable import HexMCP

@Suite("MCP dispatched-call ownership")
struct MCPToolExecutorDispatchOwnershipTests {
  @Test(
    "Successful refresh changes future routing without discarding an already dispatched result",
    arguments: [false, true])
  func dispatchedResultSurvivesCatalogRefresh(removeOriginalTool: Bool) async throws {
    let session = GatedSession()
    let executor = try MCPToolExecutor(sessions: [session])
    try await executor.start()
    let context = ToolExecutionContext(runID: AgentRunID())
    let original = ToolCall(name: "mcp_7_fixture_inspect", arguments: ["request": .integer(1)])
    let dispatched = Task { try await executor.execute(original, in: context) }

    do {
      try await session.waitUntilFirstCallStarts()
      let nextRemoteName = removeOriginalTool ? "replacement" : "inspect"
      await session.replaceCatalog(toolName: nextRemoteName, description: "Updated description")
      try await executor.refreshCatalog()
      let refreshed = try await executor.availableTools()
      #expect(refreshed.map(\.name) == ["mcp_7_fixture_\(nextRemoteName)"])
      #expect(refreshed.first?.description == "Updated description")

      await session.releaseFirstCall()
      let originalResult = try await dispatched.value
      #expect(
        originalResult
          == expectedResult(for: original, remoteName: "inspect", call: 1, connection: 1))
      #expect(
        await session.receivedCalls() == [
          MCPRemoteToolCall(name: "inspect", arguments: original.arguments)
        ])

      if removeOriginalTool {
        await #expect(throws: MCPToolExecutorError.unknownTool) {
          try await executor.execute(
            ToolCall(name: original.name, arguments: ["request": .integer(2)]), in: context)
        }
      }
      let next = ToolCall(
        name: "mcp_7_fixture_\(nextRemoteName)", arguments: ["request": .integer(3)])
      #expect(
        try await executor.execute(next, in: context)
          == expectedResult(for: next, remoteName: nextRemoteName, call: 2, connection: 1))
      #expect(
        await session.receivedCalls() == [
          MCPRemoteToolCall(name: "inspect", arguments: original.arguments),
          MCPRemoteToolCall(name: nextRemoteName, arguments: next.arguments),
        ])
      await executor.stop()
    } catch {
      await session.releaseFirstCall()
      _ = try? await dispatched.value
      await executor.stop()
      throw error
    }
  }

  @Test("A late old-connection result remains rejected after stop and restart")
  func restartedLifecycleDoesNotAcceptStaleDispatchedResult() async throws {
    let session = GatedSession()
    let executor = try MCPToolExecutor(sessions: [session])
    try await executor.start()
    let context = ToolExecutionContext(runID: AgentRunID())
    let original = ToolCall(name: "mcp_7_fixture_inspect", arguments: ["request": .integer(1)])
    let dispatched = Task { try await executor.execute(original, in: context) }

    do {
      try await session.waitUntilFirstCallStarts()
      await executor.stop()
      try await executor.start()
      #expect(try await executor.availableTools().map(\.name) == [original.name])

      // This session deliberately ignores disconnect/cancellation for its already dispatched call.
      // Reusing the same route name must not turn its old connection's output into a current result.
      await session.releaseFirstCall()
      await #expect(throws: MCPToolExecutorError.notStarted) { try await dispatched.value }
      let current = ToolCall(name: original.name, arguments: ["request": .integer(2)])
      #expect(
        try await executor.execute(current, in: context)
          == expectedResult(for: current, remoteName: "inspect", call: 2, connection: 2))
      #expect(
        await session.receivedCalls() == [
          MCPRemoteToolCall(name: "inspect", arguments: original.arguments),
          MCPRemoteToolCall(name: "inspect", arguments: current.arguments),
        ])
      await executor.stop()
    } catch {
      await session.releaseFirstCall()
      _ = try? await dispatched.value
      await executor.stop()
      throw error
    }
  }

  private func expectedResult(
    for toolCall: ToolCall, remoteName: String, call: Int64, connection: Int64
  ) -> ToolResult {
    let text = "receipt-\(call)"
    return ToolResult(
      toolCallID: toolCall.id, status: .success,
      output: .object([
        "server": .string("fixture"),
        "tool": .string(remoteName),
        "isError": .boolean(false),
        "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
        "structuredContent": .object(["call": .integer(call), "connection": .integer(connection)]),
      ]),
      content: [.text(text)])
  }

  private enum FixtureError: Error { case waitTimedOut }

  private actor GatedSession: MCPClientSession {
    nonisolated let serverID = "fixture"
    private var tools = [
      MCPRemoteTool(
        name: "inspect", description: "Original description",
        inputSchema: ["type": .string("object")])
    ]
    private var connection = Int64(0)
    private var calls: [MCPRemoteToolCall] = []
    private var firstCallReleased = false
    private var firstCallWaiter: CheckedContinuation<Void, Never>?

    func connect() async throws { connection += 1 }

    func disconnect() async {}

    func listTools() async throws -> [MCPRemoteTool] { tools }

    func callTool(_ call: MCPRemoteToolCall) async throws -> MCPRemoteToolResult {
      calls.append(call)
      let ordinal = Int64(calls.count)
      let originalConnection = connection
      if ordinal == 1, !firstCallReleased {
        await withCheckedContinuation { firstCallWaiter = $0 }
      }
      return MCPRemoteToolResult(
        content: [.text("receipt-\(ordinal)")],
        structuredContent: .object([
          "call": .integer(ordinal), "connection": .integer(originalConnection),
        ]),
        isError: false)
    }

    func replaceCatalog(toolName: String, description: String) {
      tools = [
        MCPRemoteTool(
          name: toolName, description: description, inputSchema: ["type": .string("object")])
      ]
    }

    func releaseFirstCall() {
      firstCallReleased = true
      firstCallWaiter?.resume()
      firstCallWaiter = nil
    }

    func receivedCalls() -> [MCPRemoteToolCall] { calls }

    func waitUntilFirstCallStarts() async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while calls.isEmpty {
        guard ContinuousClock.now < deadline else { throw FixtureError.waitTimedOut }
        try await Task.sleep(for: .milliseconds(1))
      }
    }
  }
}
