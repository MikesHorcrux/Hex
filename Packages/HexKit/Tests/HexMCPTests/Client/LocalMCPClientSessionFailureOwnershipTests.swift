import Foundation
import HexCore
import Testing

@testable import HexMCP

@Suite("Local MCP request failure ownership")
struct LocalMCPClientSessionFailureOwnershipTests {
  @Test(
    "A stale request failure cannot disconnect the replacement session",
    arguments: [FailureEnding.cancelled, .closed, .unexpected])
  func staleFailurePreservesReplacement(ending: FailureEnding) async throws {
    let connection = GatedConnection(ending: ending)
    let session = LocalMCPClientSession(
      configuration: try MCPServerConfiguration(
        serverID: "fixture", executableURL: URL(fileURLWithPath: "/usr/bin/true"),
        arguments: [], workingDirectory: URL(fileURLWithPath: "/"), environment: [:]),
      connection: connection)
    try await session.connect()
    _ = try await session.listTools()
    let staleCall = Task {
      try await session.callTool(MCPRemoteToolCall(name: "echo", arguments: [:]))
    }
    do {
      try await connection.waitUntilCallStarts()
      await session.disconnect()
      try await session.connect()
      _ = try await session.listTools()
      await connection.releaseFailure()
      if case .success = await staleCall.result {
        Issue.record("The stale call must retain its failure.")
      }
      #expect(await connection.disconnectCount() == 1)
      let result = try await session.callTool(MCPRemoteToolCall(name: "echo", arguments: [:]))
      #expect(result.content == [.text("Replacement works")])
      #expect(await connection.callCount() == 2)
      await session.disconnect()
    } catch {
      await connection.releaseFailure()
      _ = await staleCall.result
      await session.disconnect()
      throw error
    }
  }

  enum FailureEnding: Sendable { case cancelled, closed, unexpected }

  private enum FixtureError: Error { case waitTimedOut, unexpectedRequest }

  private actor GatedConnection: MCPJSONRPCConnection {
    private let ending: FailureEnding
    private var calls = 0
    private var disconnects = 0
    private var failureReleased = false
    private var failureWaiter: CheckedContinuation<Void, Never>?

    init(ending: FailureEnding) { self.ending = ending }

    func connect() async throws {}

    func disconnect() async { disconnects += 1 }

    func notify(method: String, params: JSONValue?) async throws {}

    func request(method: String, params: JSONValue) async throws -> JSONValue {
      switch method {
      case "initialize":
        return .object([
          "protocolVersion": .string("2025-11-25"),
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
        if calls == 1 {
          if !failureReleased {
            await withCheckedContinuation { failureWaiter = $0 }
          }
          switch ending {
          case .cancelled: throw CancellationError()
          case .closed: throw MCPClientSessionError.connectionClosed
          case .unexpected: throw FixtureError.unexpectedRequest
          }
        }
        return .object([
          "content": .array([
            .object(["type": .string("text"), "text": .string("Replacement works")])
          ]),
          "isError": .boolean(false),
        ])
      default: throw FixtureError.unexpectedRequest
      }
    }

    func releaseFailure() {
      failureReleased = true
      failureWaiter?.resume()
      failureWaiter = nil
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
