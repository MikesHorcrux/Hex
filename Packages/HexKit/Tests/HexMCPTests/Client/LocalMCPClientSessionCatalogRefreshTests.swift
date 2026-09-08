import Foundation
import HexCore
import Testing

@testable import HexMCP

@Suite("Local MCP atomic catalog refresh")
struct LocalMCPClientSessionCatalogRefreshTests {
  @Test(
    "Pending pagination retains prior tools without publishing a partial replacement",
    arguments: [RefreshEnding.valid, .invalid, .disconnected])
  func pendingRefreshKeepsOnlyCompleteCatalog(ending: RefreshEnding) async throws {
    let connection = GatedConnection(
      initialization: initialization(),
      initialPage: page(name: "echo"),
      refreshPage: page(name: "new_tool", cursor: "last-page"),
      finalPage: ending == .invalid
        ? .object(["tools": .string("invalid")])
        : .object(["tools": .array([])]))
    let session = LocalMCPClientSession(
      configuration: try MCPServerConfiguration(
        serverID: "fixture", executableURL: URL(fileURLWithPath: "/usr/bin/true"),
        arguments: [], workingDirectory: URL(fileURLWithPath: "/"), environment: [:]),
      connection: connection)
    try await session.connect()
    #expect(try await session.listTools().map(\.name) == ["echo"])
    let safetyRelease = Task {
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      await connection.releaseFinalPage()
    }
    let refresh = Task { try await session.listTools() }
    try await connection.waitUntilFinalPageRequested()

    let retained = try await session.callTool(MCPRemoteToolCall(name: "echo", arguments: [:]))
    #expect(retained.content == [.text("called")])
    await #expect(throws: MCPClientSessionError.toolsUnavailable) {
      try await session.callTool(MCPRemoteToolCall(name: "new_tool", arguments: [:]))
    }
    #expect(await connection.callCount() == 1)
    if ending == .disconnected { await session.disconnect() }
    await connection.releaseFinalPage()

    switch ending {
    case .valid:
      #expect(try await refresh.value.map(\.name) == ["new_tool"])
      await #expect(throws: MCPClientSessionError.toolsUnavailable) {
        try await session.callTool(MCPRemoteToolCall(name: "echo", arguments: [:]))
      }
      let replacement = try await session.callTool(
        MCPRemoteToolCall(name: "new_tool", arguments: [:]))
      #expect(replacement.content == [.text("called")])
      #expect(await connection.callCount() == 2)
      #expect(await connection.disconnectCount() == 0)
    case .invalid, .disconnected:
      if case .success = await refresh.result {
        Issue.record("A failed or stale refresh must not publish its catalog.")
      }
      await #expect(throws: MCPClientSessionError.notConnected) {
        try await session.callTool(MCPRemoteToolCall(name: "echo", arguments: [:]))
      }
      await #expect(throws: MCPClientSessionError.notConnected) {
        try await session.callTool(MCPRemoteToolCall(name: "new_tool", arguments: [:]))
      }
      #expect(await connection.callCount() == 1)
      #expect(await connection.disconnectCount() == 1)
    }
    safetyRelease.cancel()
    await safetyRelease.value
    await session.disconnect()
  }

  enum RefreshEnding: Equatable, Sendable { case valid, invalid, disconnected }

  private func initialization() -> JSONValue {
    .object([
      "protocolVersion": .string("2025-06-18"),
      "capabilities": .object(["tools": .object([:])]),
      "serverInfo": .object(["name": .string("Fixture"), "version": .string("1")]),
    ])
  }

  private func page(name: String, cursor: String? = nil) -> JSONValue {
    var value: [String: JSONValue] = [
      "tools": .array([
        .object([
          "name": .string(name), "inputSchema": .object(["type": .string("object")]),
        ])
      ])
    ]
    if let cursor { value["nextCursor"] = .string(cursor) }
    return .object(value)
  }

  private enum FixtureError: Error { case waitTimedOut, unexpectedRequest }

  private actor GatedConnection: MCPJSONRPCConnection {
    private let initialization: JSONValue
    private let initialPage: JSONValue
    private let refreshPage: JSONValue
    private let finalPage: JSONValue
    private var lists = 0
    private var calls = 0
    private var disconnects = 0
    private var finalPageReleased = false
    private var finalPageWaiter: CheckedContinuation<Void, Never>?

    init(
      initialization: JSONValue, initialPage: JSONValue, refreshPage: JSONValue,
      finalPage: JSONValue
    ) {
      self.initialization = initialization
      self.initialPage = initialPage
      self.refreshPage = refreshPage
      self.finalPage = finalPage
    }

    func connect() async throws {}

    func disconnect() async { disconnects += 1 }

    func notify(method: String, params: JSONValue?) async throws {}

    func request(method: String, params: JSONValue) async throws -> JSONValue {
      switch method {
      case "initialize": return initialization
      case "tools/list":
        lists += 1
        switch lists {
        case 1: return initialPage
        case 2: return refreshPage
        case 3:
          if !finalPageReleased {
            // Ignore cancellation until released, so the real session's lifecycle fence is tested.
            await withCheckedContinuation { finalPageWaiter = $0 }
          }
          return finalPage
        default: throw FixtureError.unexpectedRequest
        }
      case "tools/call":
        calls += 1
        return .object([
          "content": .array([.object(["type": .string("text"), "text": .string("called")])]),
          "isError": .boolean(false),
        ])
      default: throw FixtureError.unexpectedRequest
      }
    }

    func releaseFinalPage() {
      finalPageReleased = true
      finalPageWaiter?.resume()
      finalPageWaiter = nil
    }

    func waitUntilFinalPageRequested() async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while lists < 3 {
        guard ContinuousClock.now < deadline else { throw FixtureError.waitTimedOut }
        try await Task.sleep(for: .milliseconds(1))
      }
    }

    func callCount() -> Int { calls }

    func disconnectCount() -> Int { disconnects }
  }
}
