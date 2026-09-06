import HexCore
import Testing

@testable import HexMCP

@Suite("Managed MCP ready catalog refresh ownership")
struct MCPManagedToolExecutorRefreshTests {
  @Test("Concurrent ready refreshes share one fetch and retain healthy tools")
  func concurrentReadyRefreshesDoNotInvalidateEachOther() async throws {
    let session = GatedRefreshSession()
    let executor = try MCPManagedToolExecutor(session: session)
    #expect(try await executor.availableTools().map(\.name) == ["mcp_7_fixture_echo"])
    let safetyRelease = releaseEventually(session)
    let first = Task { try await executor.refreshCatalog() }
    try await session.waitUntilRefreshStarts()
    let second = Task { try await executor.refreshCatalog() }
    // Allow both actor callers to enter while the server deliberately holds the first fetch.
    try await Task.sleep(for: .milliseconds(50))
    #expect(try await executor.availableTools().map(\.name) == ["mcp_7_fixture_echo"])
    #expect(await session.listCount() == 2)
    await session.releaseRefresh()

    let firstResult = await first.result
    let secondResult = await second.result
    #expect(isSuccess(firstResult))
    #expect(isSuccess(secondResult))
    #expect(await session.listCount() == 2)
    #expect(await executor.currentState() == .ready)
    #expect(try await executor.availableTools().map(\.name) == ["mcp_7_fixture_echo"])
    #expect(await session.disconnectCount() == 0)
    safetyRelease.cancel()
    await safetyRelease.value
    await executor.stop()
  }

  @Test("Stop joins an in-flight refresh and prevents its late result from reopening the catalog")
  func stopJoinsReadyRefreshBeforeRestart() async throws {
    let session = GatedRefreshSession()
    let executor = try MCPManagedToolExecutor(session: session)
    #expect(try await executor.availableTools().count == 1)
    let safetyRelease = releaseEventually(session)
    let refresh = Task { try await executor.refreshCatalog() }
    try await session.waitUntilRefreshStarts()
    let completion = StopCompletion()
    let stop = Task {
      await executor.stop()
      await completion.markFinished()
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await executor.currentState() != .disconnected {
      guard ContinuousClock.now < deadline else { throw FixtureError.waitTimedOut }
      try await Task.sleep(for: .milliseconds(1))
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(!(await completion.isFinished()))
    #expect(try await executor.availableTools().isEmpty)
    #expect(await session.connectCount() == 1)

    await session.releaseRefresh()
    await stop.value
    #expect(!isSuccess(await refresh.result))
    #expect(await executor.currentState() == .disconnected)
    #expect(await session.disconnectCount() == 1)
    #expect(try await executor.availableTools().map(\.name) == ["mcp_7_fixture_echo"])
    #expect(await session.connectCount() == 2)
    #expect(await executor.currentState() == .ready)
    safetyRelease.cancel()
    await safetyRelease.value
    await executor.stop()
  }

  @Test("Cancelling a refresh waiter does not cancel the owned background recovery")
  func cancelledRefreshWaiterLeavesBackgroundStartupOwned() async throws {
    let session = GatedRefreshSession(failFirstConnection: true)
    let executor = try MCPManagedToolExecutor(
      session: session, startupTimeout: .seconds(5), retryDelay: .zero)
    #expect(try await executor.availableTools().isEmpty)
    let safetyRelease = releaseEventually(session)
    #expect(try await executor.availableTools().isEmpty)
    try await session.waitUntilConnections(2)
    let refresh = Task { try await executor.refreshCatalog() }
    try await Task.sleep(for: .milliseconds(50))
    let cancelledAt = ContinuousClock.now
    refresh.cancel()
    await #expect(throws: CancellationError.self) { try await refresh.value }
    #expect(ContinuousClock.now - cancelledAt < .milliseconds(1_500))
    #expect(await executor.currentState() == .connecting)
    #expect(try await executor.availableTools().isEmpty)
    #expect(await session.connectCount() == 2)

    await session.releaseRefresh()
    try await executor.refreshCatalog()
    #expect(await executor.currentState() == .ready)
    #expect(try await executor.availableTools().map(\.name) == ["mcp_7_fixture_echo"])
    #expect(await session.connectCount() == 2)
    safetyRelease.cancel()
    await safetyRelease.value
    await executor.stop()
  }

  private func isSuccess(_ result: Result<Void, any Error>) -> Bool {
    if case .success = result { return true }
    return false
  }

  private func releaseEventually(_ session: GatedRefreshSession) -> Task<Void, Never> {
    Task {
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      await session.releaseRefresh()
    }
  }

  private enum FixtureError: Error {
    case waitTimedOut
    case unavailable
  }

  private actor StopCompletion {
    private var finished = false

    func markFinished() { finished = true }

    func isFinished() -> Bool { finished }
  }

  private actor GatedRefreshSession: MCPClientSession {
    nonisolated let serverID = "fixture"
    private let failFirstConnection: Bool
    private var connects = 0
    private var disconnects = 0
    private var lists = 0
    private var released = false
    private var pendingRefreshes: [CheckedContinuation<Void, Never>] = []

    init(failFirstConnection: Bool = false) {
      self.failFirstConnection = failFirstConnection
    }

    func connect() async throws {
      connects += 1
      if failFirstConnection {
        if connects == 1 { throw FixtureError.unavailable }
        if !released {
          await withCheckedContinuation { pendingRefreshes.append($0) }
        }
      }
    }

    func disconnect() async { disconnects += 1 }

    func listTools() async throws -> [MCPRemoteTool] {
      lists += 1
      if lists > 1, !released {
        // Deliberately ignore cancellation until released to test owned, joined cleanup.
        await withCheckedContinuation { pendingRefreshes.append($0) }
      }
      return [MCPRemoteTool(name: "echo", inputSchema: ["type": .string("object")])]
    }

    func callTool(_ call: MCPRemoteToolCall) async throws -> MCPRemoteToolResult {
      MCPRemoteToolResult(content: [.text(call.name)], isError: false)
    }

    func connectCount() -> Int { connects }

    func disconnectCount() -> Int { disconnects }

    func listCount() -> Int { lists }

    func releaseRefresh() {
      released = true
      let pending = pendingRefreshes
      pendingRefreshes = []
      for continuation in pending { continuation.resume() }
    }

    func waitUntilRefreshStarts() async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while lists < 2 {
        guard ContinuousClock.now < deadline else { throw FixtureError.waitTimedOut }
        try await Task.sleep(for: .milliseconds(1))
      }
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
