import Foundation
import HexCore
import Testing

@testable import HexMCP

@Suite("MCP known receipts during cancellation")
struct MCPKnownReceiptCancellationTests {
  @Test(
    "Cancellation preserves only validated same-session receipts and never permits another call",
    arguments: [ReceiptEnding.valid, .malformed, .restarted])
  func returnedReceiptCrossesRealSessionAdapters(ending: ReceiptEnding) async throws {
    let connection = GatedConnection(malformedResult: ending == .malformed)
    let local = LocalMCPClientSession(
      configuration: try MCPServerConfiguration(
        serverID: "fixture", executableURL: URL(fileURLWithPath: "/usr/bin/true"),
        arguments: [], workingDirectory: URL(fileURLWithPath: "/"), environment: [:]),
      connection: connection)
    let deferred = try MCPDeferredClientSession(serverID: "fixture") { local }
    let executor = try MCPToolExecutor(sessions: [deferred])
    try await executor.start()
    let original = ToolCall(name: "mcp_7_fixture_echo", arguments: ["request": .integer(1)])
    let context = ToolExecutionContext(runID: AgentRunID())
    let dispatched = Task {
      let result = try await executor.execute(original, in: context)
      await #expect(throws: CancellationError.self) {
        try await executor.execute(
          ToolCall(name: original.name, arguments: ["request": .integer(2)]), in: context)
      }
      return result
    }

    do {
      try await connection.waitUntilCallStarts()
      dispatched.cancel()
      if ending == .restarted {
        await executor.stop()
        try await executor.start()
      }
      await connection.releaseResult()

      switch ending {
      case .valid:
        #expect(
          try await dispatched.value
            == ToolResult(
              toolCallID: original.id, status: .success,
              output: .object([
                "server": .string("fixture"), "tool": .string("echo"),
                "isError": .boolean(false),
                "content": .array([
                  .object(["type": .string("text"), "text": .string("Action completed")])
                ]),
                "structuredContent": .object(["receipt": .integer(1)]),
              ]),
              content: [.text("Action completed")]))
        #expect(await connection.disconnectCount() == 0)
      case .malformed:
        await #expect(throws: MCPClientSessionError.protocolViolation) {
          try await dispatched.value
        }
        #expect(await connection.disconnectCount() == 1)
      case .restarted:
        await #expect(throws: MCPClientSessionError.connectionClosed) {
          try await dispatched.value
        }
        #expect(try await executor.availableTools().map(\.name) == [original.name])
      }
      #expect(await connection.callCount() == 1)
      await executor.stop()
    } catch {
      await connection.releaseResult()
      _ = await dispatched.result
      await executor.stop()
      throw error
    }
  }

  enum ReceiptEnding: Equatable, Sendable { case valid, malformed, restarted }

  private enum FixtureError: Error { case waitTimedOut, unexpectedRequest }

  private actor GatedConnection: MCPJSONRPCConnection {
    private let malformedResult: Bool
    private var calls = 0
    private var disconnects = 0
    private var resultReleased = false
    private var resultWaiter: CheckedContinuation<Void, Never>?

    init(malformedResult: Bool) { self.malformedResult = malformedResult }

    func connect() async throws {}

    func disconnect() async { disconnects += 1 }

    func notify(method: String, params: JSONValue?) async throws {}

    func request(method: String, params: JSONValue) async throws -> JSONValue {
      switch method {
      case "initialize":
        return .object([
          "protocolVersion": .string("2025-06-18"),
          "capabilities": .object(["tools": .object([:])]),
          "serverInfo": .object(["name": .string("Fixture"), "version": .string("1")]),
        ])
      case "tools/list":
        return .object([
          "tools": .array([
            .object([
              "name": .string("echo"), "inputSchema": .object(["type": .string("object")]),
            ])
          ])
        ])
      case "tools/call":
        calls += 1
        if !resultReleased {
          // Model a server whose action completes after caller cancellation or disconnection.
          await withCheckedContinuation { resultWaiter = $0 }
        }
        if malformedResult { return .object(["content": .string("invalid")]) }
        return .object([
          "content": .array([
            .object(["type": .string("text"), "text": .string("Action completed")])
          ]),
          "structuredContent": .object(["receipt": .integer(1)]),
          "isError": .boolean(false),
        ])
      default: throw FixtureError.unexpectedRequest
      }
    }

    func releaseResult() {
      resultReleased = true
      resultWaiter?.resume()
      resultWaiter = nil
    }

    func waitUntilCallStarts() async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while calls == 0 {
        guard ContinuousClock.now < deadline else { throw FixtureError.waitTimedOut }
        try await Task.sleep(for: .milliseconds(1))
      }
    }

    func callCount() -> Int { calls }

    func disconnectCount() -> Int { disconnects }
  }
}
