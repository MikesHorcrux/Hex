import Foundation
import HexCore
import Testing

@testable import HexMCP

@Suite("Streamable HTTP MCP receipt ownership")
struct StreamableHTTPMCPClientSessionReceiptTests {
  @Test(
    "Late cancellation preserves only a valid same-session HTTP receipt",
    arguments: [ReceiptEnding.valid, .malformed, .restarted], [false, true])
  func preservesValidatedReceiptAfterCancellation(ending: ReceiptEnding, usesSSE: Bool) async throws
  {
    let endpoint = try #require(URL(string: "http://127.0.0.1:8765/mcp"))
    let transport = GatedTransport(
      endpoint: endpoint, malformedResult: ending == .malformed, usesSSE: usesSSE)
    let session = StreamableHTTPMCPClientSession(
      configuration: try MCPStreamableHTTPServerConfiguration(
        serverID: "fixture", endpointURL: endpoint),
      headerProvider: MCPEmptyHTTPHeaderProvider(), transport: transport)
    let executor = try MCPToolExecutor(sessions: [session])
    try await executor.start()
    let call = ToolCall(name: "mcp_7_fixture_echo", arguments: [:])
    let context = ToolExecutionContext(runID: AgentRunID())
    let dispatched = Task {
      let result = try await executor.execute(call, in: context)
      await #expect(throws: CancellationError.self) {
        try await executor.execute(
          ToolCall(name: call.name, arguments: [:]), in: context)
      }
      return result
    }

    do {
      try await transport.waitUntilCallStarts()
      dispatched.cancel()
      if ending == .restarted {
        await executor.stop()
        try await executor.start()
      }
      await transport.releaseResult()

      switch ending {
      case .valid:
        let result = try await dispatched.value
        #expect(result.toolCallID == call.id)
        #expect(result.status == .success)
        #expect(result.content == [.text("Action completed")])
        #expect(await transport.deleteCount() == 0)
      case .malformed:
        await #expect(throws: MCPClientSessionError.protocolViolation) {
          try await dispatched.value
        }
      case .restarted:
        await #expect(throws: MCPClientSessionError.connectionClosed) {
          try await dispatched.value
        }
      }
      #expect(await transport.callCount() == 1)
      await executor.stop()
    } catch {
      await transport.releaseResult()
      _ = await dispatched.result
      await executor.stop()
      throw error
    }
  }

  enum ReceiptEnding: Equatable, Sendable { case valid, malformed, restarted }

  private enum FixtureError: Error { case waitTimedOut, unexpectedRequest }

  private actor GatedTransport: MCPHTTPTransport {
    private let endpoint: URL
    private let malformedResult: Bool
    private let usesSSE: Bool
    private var calls = 0
    private var deletes = 0
    private var resultReleased = false
    private var resultWaiter: CheckedContinuation<Void, Never>?

    init(endpoint: URL, malformedResult: Bool, usesSSE: Bool) {
      self.endpoint = endpoint
      self.malformedResult = malformedResult
      self.usesSSE = usesSSE
    }

    func send(
      _ request: URLRequest, maximumResponseBytes: Int
    ) async throws -> MCPHTTPResponse {
      if request.httpMethod == "DELETE" {
        deletes += 1
        return accepted()
      }
      guard let body = request.httpBody,
        let object = try JSONDecoder().decode(JSONValue.self, from: body).mcpObject,
        let method = object["method"]?.mcpString
      else { throw FixtureError.unexpectedRequest }
      if method == "notifications/initialized" { return accepted() }
      guard let requestID = object["id"]?.mcpInteger else {
        throw FixtureError.unexpectedRequest
      }
      let result: JSONValue
      switch method {
      case "initialize":
        result = .object([
          "protocolVersion": .string("2025-11-25"),
          "capabilities": .object(["tools": .object([:])]),
          "serverInfo": .object(["name": .string("Fixture"), "version": .string("1")]),
        ])
      case "tools/list":
        result = .object([
          "tools": .array([
            .object([
              "name": .string("echo"), "inputSchema": .object(["type": .string("object")]),
            ])
          ])
        ])
      case "tools/call":
        calls += 1
        if !resultReleased {
          // The server completed the operation before cancellation reached its returned response.
          await withCheckedContinuation { resultWaiter = $0 }
        }
        result =
          malformedResult
          ? .object(["content": .string("invalid")])
          : .object([
            "content": .array([
              .object(["type": .string("text"), "text": .string("Action completed")])
            ]),
            "isError": .boolean(false),
          ])
      default: throw FixtureError.unexpectedRequest
      }
      let responseBody = try JSONEncoder().encode(
        JSONValue.object([
          "jsonrpc": .string("2.0"), "id": .integer(requestID), "result": result,
        ]))
      let streamsResult = usesSSE && method == "tools/call"
      return MCPHTTPResponse(
        statusCode: 200,
        headers: [
          "content-type": streamsResult ? "text/event-stream" : "application/json",
          "mcp-session-id": "fixture-session",
        ],
        body: streamsResult
          ? Data("data: \(String(decoding: responseBody, as: UTF8.self))\n\n".utf8)
          : responseBody,
        finalURL: endpoint)
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

    func deleteCount() -> Int { deletes }

    private func accepted() -> MCPHTTPResponse {
      MCPHTTPResponse(statusCode: 202, headers: [:], body: Data(), finalURL: endpoint)
    }
  }
}
