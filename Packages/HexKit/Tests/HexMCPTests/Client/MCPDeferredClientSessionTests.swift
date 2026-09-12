import Foundation
import HexCore
import Testing

@testable import HexMCP

@Suite("Deferred optional MCP session")
struct MCPDeferredClientSessionTests {
  @Test
  func missingPrerequisiteCanRecoverAfterExplicitRefreshWithoutLosingIdentity() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("HexDeferredMCP-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let prerequisite = root.appendingPathComponent("installed-marker")
    let session = FixtureSession(serverID: "fixture")
    let deferred = try MCPDeferredClientSession(serverID: "fixture") {
      guard FileManager.default.fileExists(atPath: prerequisite.path) else {
        throw MCPManagedToolLayoutError.invalidInstallation(.peekaboo)
      }
      return session
    }
    let executor = try MCPManagedToolExecutor(session: deferred)

    #expect(await session.connectionCount() == 0)
    #expect(try await executor.availableTools().isEmpty)
    #expect(await executor.currentState() == .unavailable)
    #expect(deferred.serverID == "fixture")
    #expect(await session.connectionCount() == 0)

    try Data([1]).write(to: prerequisite)
    try await executor.refreshCatalog()
    #expect(try await executor.availableTools().map(\.name) == ["mcp_7_fixture_echo"])
    #expect(await executor.currentState() == .ready)
    #expect(await session.connectionCount() == 1)
    await executor.stop()
    #expect(await session.disconnectionCount() == 1)
  }

  @Test
  func malformedIdentityIsRejectedBeforeFactoryCanRun() {
    #expect(throws: MCPServerConfigurationError.invalidServerID) {
      try MCPDeferredClientSession(serverID: "Bad server ID") {
        throw FixtureError.factoryMustNotRun
      }
    }
  }

  @Test
  func factoryCannotSubstituteADifferentServerIdentity() async throws {
    let session = FixtureSession(serverID: "other")
    let deferred = try MCPDeferredClientSession(serverID: "fixture") { session }

    await #expect(throws: MCPClientSessionError.protocolViolation) {
      try await deferred.connect()
    }
    #expect(await session.connectionCount() == 0)
    await #expect(throws: MCPClientSessionError.notConnected) {
      try await deferred.listTools()
    }
  }

  @Test
  func cancelledConnectDrainsItsSessionAndCanRetry() async throws {
    let session = CancellableSession()
    let deferred = try MCPDeferredClientSession(serverID: "fixture") { session }
    let connection = Task { try await deferred.connect() }
    await session.waitUntilConnecting()

    await #expect(throws: MCPClientSessionError.notConnected) {
      try await deferred.listTools()
    }
    connection.cancel()
    await #expect(throws: CancellationError.self) { try await connection.value }
    #expect(await session.disconnectionCount() == 1)

    await session.allowConnection()
    try await deferred.connect()
    #expect(try await deferred.listTools().isEmpty)
    await deferred.disconnect()
    #expect(await session.disconnectionCount() == 2)
  }

  @Test
  func disconnectPreventsLateConnectionFromBecomingReady() async throws {
    let session = LateConnectingSession()
    let deferred = try MCPDeferredClientSession(serverID: "fixture") { session }
    let connection = Task { try await deferred.connect() }
    await session.waitUntilConnecting()

    await deferred.disconnect()
    await #expect(throws: MCPClientSessionError.connectionClosed) { try await connection.value }
    await #expect(throws: MCPClientSessionError.notConnected) {
      try await deferred.callTool(MCPRemoteToolCall(name: "echo", arguments: [:]))
    }
    try await deferred.connect()
    #expect(try await deferred.listTools().isEmpty)
    await deferred.disconnect()
  }

  @Test
  func shutdownDrainsNoncooperativeLateActivationBeforeAllowingReuse() async throws {
    let session = NoncooperativeSession()
    let deferred = try MCPDeferredClientSession(serverID: "fixture") { session }
    let connection = Task { try await deferred.connect() }
    await session.waitUntilConnecting()
    let shutdown = Task { await deferred.disconnect() }
    await session.waitUntilFirstDisconnect()

    await #expect(throws: MCPClientSessionError.alreadyConnected) {
      try await deferred.connect()
    }
    await session.releaseLateConnection()
    await shutdown.value
    await #expect(throws: MCPClientSessionError.connectionClosed) { try await connection.value }
    #expect(!(await session.hasLiveConnection()))

    try await deferred.connect()
    #expect(await session.hasLiveConnection())
    await deferred.disconnect()
    #expect(!(await session.hasLiveConnection()))
  }

  private enum FixtureError: Error { case factoryMustNotRun }

  private actor FixtureSession: MCPClientSession {
    nonisolated let serverID: String
    private var connections = 0
    private var disconnections = 0

    init(serverID: String) { self.serverID = serverID }
    func connect() async throws { connections += 1 }
    func disconnect() async { disconnections += 1 }
    func listTools() async throws -> [MCPRemoteTool] {
      [MCPRemoteTool(name: "echo", inputSchema: ["type": .string("object")])]
    }
    func callTool(_ call: MCPRemoteToolCall) async throws -> MCPRemoteToolResult {
      MCPRemoteToolResult(content: [.text(call.name)], isError: false)
    }
    func connectionCount() -> Int { connections }
    func disconnectionCount() -> Int { disconnections }
  }

  private actor CancellableSession: MCPClientSession {
    nonisolated let serverID = "fixture"
    private var isConnecting = false
    private var shouldWait = true
    private var disconnections = 0
    private var started: CheckedContinuation<Void, Never>?

    func connect() async throws {
      isConnecting = true
      started?.resume()
      started = nil
      if shouldWait { try await Task.sleep(for: .seconds(60)) }
    }
    func disconnect() async { disconnections += 1 }
    func listTools() async throws -> [MCPRemoteTool] { [] }
    func callTool(_ call: MCPRemoteToolCall) async throws -> MCPRemoteToolResult {
      throw MCPClientSessionError.toolsUnavailable
    }
    func waitUntilConnecting() async {
      guard !isConnecting else { return }
      await withCheckedContinuation { started = $0 }
    }
    func allowConnection() { shouldWait = false }
    func disconnectionCount() -> Int { disconnections }
  }

  private actor LateConnectingSession: MCPClientSession {
    nonisolated let serverID = "fixture"
    private var isConnecting = false
    private var hasDisconnected = false
    private var started: CheckedContinuation<Void, Never>?
    private var connection: CheckedContinuation<Void, Never>?

    func connect() async throws {
      guard !hasDisconnected else { return }
      await withCheckedContinuation { continuation in
        connection = continuation
        isConnecting = true
        started?.resume()
        started = nil
      }
    }
    func disconnect() async {
      hasDisconnected = true
      connection?.resume()
      connection = nil
    }
    func listTools() async throws -> [MCPRemoteTool] { [] }
    func callTool(_ call: MCPRemoteToolCall) async throws -> MCPRemoteToolResult {
      throw MCPClientSessionError.toolsUnavailable
    }
    func waitUntilConnecting() async {
      guard !isConnecting else { return }
      await withCheckedContinuation { started = $0 }
    }
  }

  private actor NoncooperativeSession: MCPClientSession {
    nonisolated let serverID = "fixture"
    private var connections = 0
    private var disconnections = 0
    private var isLive = false
    private var connection: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var disconnected: CheckedContinuation<Void, Never>?

    func connect() async throws {
      connections += 1
      if connections == 1 {
        // Deliberately ignore cancellation and allow resources to become live after disconnect.
        await withCheckedContinuation { continuation in
          connection = continuation
          started?.resume()
          started = nil
        }
      }
      isLive = true
    }
    func disconnect() async {
      disconnections += 1
      isLive = false
      disconnected?.resume()
      disconnected = nil
    }
    func listTools() async throws -> [MCPRemoteTool] { [] }
    func callTool(_ call: MCPRemoteToolCall) async throws -> MCPRemoteToolResult {
      throw MCPClientSessionError.toolsUnavailable
    }
    func waitUntilConnecting() async {
      guard connections == 0 else { return }
      await withCheckedContinuation { started = $0 }
    }
    func waitUntilFirstDisconnect() async {
      guard disconnections == 0 else { return }
      await withCheckedContinuation { disconnected = $0 }
    }
    func releaseLateConnection() {
      connection?.resume()
      connection = nil
    }
    func hasLiveConnection() -> Bool { isLive }
  }
}
