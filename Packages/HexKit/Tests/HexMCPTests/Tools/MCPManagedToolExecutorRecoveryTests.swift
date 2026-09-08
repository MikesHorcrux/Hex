import HexCore
import Testing

@testable import HexMCP

@Suite("Optional MCP background recovery")
struct MCPManagedToolExecutorRecoveryTests {
  @Test("Cold optional startup returns promptly, coalesces, and later publishes real tools")
  func nonblockingColdDiscoveryPreservesAnOwnedAttempt() async throws {
    let session = GatedSession(failFirstConnection: false)
    let executor = try MCPManagedToolExecutor(
      session: session, startupTimeout: .seconds(5), waitsForInitialDiscovery: false)
    let safetyRelease = releaseEventually(session)
    let began = ContinuousClock.now
    #expect(try await executor.availableTools().isEmpty)
    try await session.waitUntilConnections(1)
    await executor.warmUp()
    for _ in 0..<20 { #expect(try await executor.availableTools().isEmpty) }
    #expect(ContinuousClock.now - began < .milliseconds(1_500))
    #expect(await executor.currentState() == .connecting)
    #expect(await session.connectionCount() == 1)
    await session.releaseConnection()
    try await executor.refreshCatalog()
    safetyRelease.cancel()
    await safetyRelease.value
    #expect(try await executor.availableTools().map(\.name) == ["mcp_7_fixture_echo"])
    #expect(await session.connectionCount() == 1)
    await executor.stop()
  }

  @Test("Resident warm-up is idempotent and cannot publish ready after shutdown")
  func warmUpIsOwnedByShutdown() async throws {
    let session = GatedSession(failFirstConnection: false)
    let executor = try MCPManagedToolExecutor(session: session, waitsForInitialDiscovery: false)
    let safetyRelease = releaseEventually(session)
    await executor.warmUp()
    await executor.warmUp()
    try await session.waitUntilConnections(1)
    #expect(try await executor.availableTools().isEmpty)
    let shutdown = Task { await executor.stop() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await executor.currentState() != .disconnected {
      guard ContinuousClock.now < deadline else { throw FixtureError.waitTimedOut }
      try await Task.sleep(for: .milliseconds(1))
    }
    await executor.warmUp()
    #expect(await session.connectionCount() == 1)
    await session.releaseConnection()
    await shutdown.value
    safetyRelease.cancel()
    await safetyRelease.value
    #expect(await executor.currentState() == .disconnected)
    #expect(await session.disconnectionCount() == 1)
  }

  @Test("Repeated discoveries do not retry a known failure during its cooldown")
  func failedServerCooldownDoesNotBlockDiscovery() async throws {
    let session = GatedSession()
    let executor = try MCPManagedToolExecutor(
      session: session, startupTimeout: .seconds(5), retryDelay: .seconds(300)
    )
    #expect(try await executor.availableTools().isEmpty)

    for _ in 0..<20 {
      #expect(try await executor.availableTools().isEmpty)
    }
    #expect(await session.connectionCount() == 1)
    #expect(await executor.currentState() == .unavailable)

    // Explicit user refresh bypasses the cooldown, rather than relying on the next chat to block.
    let safetyRelease = releaseEventually(session)
    let refresh = Task { try await executor.refreshCatalog() }
    try await session.waitUntilConnections(2)
    #expect(try await executor.availableTools().isEmpty)
    #expect(await session.connectionCount() == 2)
    await session.releaseConnection()
    try await refresh.value
    safetyRelease.cancel()
    await safetyRelease.value
    #expect(try await executor.availableTools().map(\.name) == ["mcp_7_fixture_echo"])
    #expect(await session.connectionCount() == 2)
    await executor.stop()
  }

  @Test("Only one background attempt runs while ordinary discovery remains nonblocking")
  func backgroundRecoveryCoalescesAndRestoresValidatedTools() async throws {
    let session = GatedSession()
    let executor = try MCPManagedToolExecutor(
      session: session, startupTimeout: .seconds(5), retryDelay: .zero
    )
    #expect(try await executor.availableTools().isEmpty)
    let safetyRelease = releaseEventually(session)
    let began = ContinuousClock.now
    #expect(try await executor.availableTools().isEmpty)
    try await session.waitUntilConnections(2)

    for _ in 0..<20 {
      #expect(try await executor.availableTools().isEmpty)
    }
    #expect(ContinuousClock.now - began < .milliseconds(1_500))
    #expect(await executor.currentState() == .connecting)
    #expect(await session.connectionCount() == 2)

    await session.releaseConnection()
    // An explicit refresh joins the owned retry, rather than starting another connection.
    try await executor.refreshCatalog()
    safetyRelease.cancel()
    await safetyRelease.value
    #expect(await executor.currentState() == .ready)
    #expect(try await executor.availableTools().map(\.name) == ["mcp_7_fixture_echo"])
    #expect(await session.connectionCount() == 2)
    await executor.stop()
  }

  @Test("Stopping joins a late background activation and fences concurrent rediscovery")
  func stopJoinsBackgroundAttemptWithoutLateReady() async throws {
    let session = GatedSession()
    let executor = try MCPManagedToolExecutor(
      session: session, startupTimeout: .seconds(5), retryDelay: .zero
    )
    #expect(try await executor.availableTools().isEmpty)
    let safetyRelease = releaseEventually(session)
    #expect(try await executor.availableTools().isEmpty)
    try await session.waitUntilConnections(2)
    let shutdown = Task { await executor.stop() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await executor.currentState() != .disconnected {
      guard ContinuousClock.now < deadline else { throw FixtureError.waitTimedOut }
      try await Task.sleep(for: .milliseconds(1))
    }

    #expect(try await executor.availableTools().isEmpty)
    #expect(await session.connectionCount() == 2)
    #expect(await session.disconnectionCount() == 0)
    await session.releaseConnection()
    await shutdown.value
    safetyRelease.cancel()
    await safetyRelease.value

    #expect(await executor.currentState() == .disconnected)
    #expect(await session.disconnectionCount() == 1)
    #expect(try await executor.availableTools().map(\.name) == ["mcp_7_fixture_echo"])
    #expect(await executor.currentState() == .ready)
    #expect(await session.connectionCount() == 3)
    await executor.stop()
  }

  private func releaseEventually(_ session: GatedSession) -> Task<Void, Never> {
    Task {
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      await session.releaseConnection()
    }
  }

  private enum FixtureError: Error {
    case unavailable
    case waitTimedOut
  }

  private actor GatedSession: MCPClientSession {
    nonisolated let serverID = "fixture"
    private var connects = 0
    private var disconnects = 0
    private var released = false
    private var connectionContinuation: CheckedContinuation<Void, Never>?
    private let failFirstConnection: Bool

    init(failFirstConnection: Bool = true) {
      self.failFirstConnection = failFirstConnection
    }

    func connect() async throws {
      connects += 1
      if connects == 1, failFirstConnection { throw FixtureError.unavailable }
      if !released {
        // Intentionally ignore cancellation until released: stop must join even a late activation.
        await withCheckedContinuation { connectionContinuation = $0 }
      }
    }

    func disconnect() async { disconnects += 1 }

    func listTools() async throws -> [MCPRemoteTool] {
      [MCPRemoteTool(name: "echo", inputSchema: ["type": .string("object")])]
    }

    func callTool(_ call: MCPRemoteToolCall) async throws -> MCPRemoteToolResult {
      MCPRemoteToolResult(content: [.text(call.name)], isError: false)
    }

    func connectionCount() -> Int { connects }

    func disconnectionCount() -> Int { disconnects }

    func releaseConnection() {
      released = true
      connectionContinuation?.resume()
      connectionContinuation = nil
    }

    func waitUntilConnections(_ count: Int) async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while connects < count {
        guard ContinuousClock.now < deadline else { throw FixtureError.waitTimedOut }
        try await Task.sleep(for: .milliseconds(1))
      }
    }
  }
}
