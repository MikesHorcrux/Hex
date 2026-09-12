import HexCore
import Testing

@testable import HexMCP

@Suite("Managed MCP tool executor")
struct MCPManagedToolExecutorTests {
  @Test("Explicit refresh reconnects unavailable servers without waiting for the cooldown")
  func explicitRefreshReconnectsUnavailableServer() async throws {
    let session = RecoveringSession(serverID: "fixture", isAvailable: false)
    let executor = try MCPManagedToolExecutor(session: session)

    #expect(try await executor.availableTools().isEmpty)
    #expect(await executor.currentState() == .unavailable)

    await session.setAvailable(true)
    #expect(try await executor.availableTools().isEmpty)
    try await executor.refreshCatalog()
    #expect(try await executor.availableTools().map(\.name) == ["mcp_7_fixture_echo"])
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
        ToolCall(name: "mcp_7_fixture_echo", arguments: [:]),
        in: ToolExecutionContext(runID: AgentRunID())
      )
    }
    #expect(await executor.currentState() == .unavailable)
    #expect(await session.connectionCounts().disconnects == 1)
  }

  @Test("A stalled optional server times out, drains cleanup, and retries at discovery")
  func stalledServerTimesOutAndRetries() async throws {
    let session = StallingSession(serverID: "fixture")
    let executor = try MCPManagedToolExecutor(
      session: session,
      startupTimeout: .milliseconds(250)
    )
    let clock = ContinuousClock()
    let startedAt = clock.now

    #expect(try await executor.availableTools().isEmpty)
    // This suite runs alongside the package's CPU-heavy integrity fixtures. Allow scheduling
    // headroom while still distinguishing the 250ms deadline from the 60-second stalled connect.
    #expect(clock.now - startedAt < .seconds(5))
    #expect(await executor.currentState() == .unavailable)
    // The deadline deliberately returns before slow cancellation cleanup. Join that cleanup
    // before asserting its side effects and asking the same process to start again.
    await executor.stop()
    #expect(await session.counts() == StallCounts(connects: 1, cancellations: 1))

    await session.allowConnections()
    #expect(try await executor.availableTools().map(\.name) == ["mcp_7_fixture_echo"])
    #expect(await executor.currentState() == .ready)
    #expect(await session.counts() == StallCounts(connects: 2, cancellations: 1))

    await executor.stop()
  }

  @Test("A startup deadline does not wait for slow cancellation cleanup")
  func startupDeadlineDoesNotWaitForCleanup() async throws {
    let session = SlowCancellationSession(serverID: "fixture")
    let executor = try MCPManagedToolExecutor(
      session: session,
      startupTimeout: .milliseconds(50)
    )
    let safetyRelease = Task {
      do {
        try await Task.sleep(for: .seconds(3))
      } catch {
        return
      }
      await session.releaseCancellationCleanup()
    }
    let clock = ContinuousClock()
    let startedAt = clock.now

    #expect(try await executor.availableTools().isEmpty)
    #expect(clock.now - startedAt < .milliseconds(1_500))
    #expect(!(await session.cleanupDidFinish()))
    #expect(await executor.currentState() == .unavailable)

    let retryStartedAt = clock.now
    #expect(try await executor.availableTools().isEmpty)
    #expect(clock.now - retryStartedAt < .milliseconds(1_500))

    await session.releaseCancellationCleanup()
    safetyRelease.cancel()
    await safetyRelease.value
    await executor.stop()

    #expect(try await executor.availableTools().map(\.name) == ["mcp_7_fixture_echo"])
    #expect(await session.counts() == SlowCleanupCounts(connects: 2, cancellations: 1))
    await executor.stop()
  }

  @Test("Cancelling discovery stops a stalled optional server promptly")
  func cancellationStopsStalledServer() async throws {
    let session = StallingSession(serverID: "fixture")
    let executor = try MCPManagedToolExecutor(
      session: session,
      startupTimeout: .seconds(5)
    )
    let discovery = Task {
      try await executor.availableTools()
    }
    await session.waitUntilConnectionStarts()
    let clock = ContinuousClock()
    let cancelledAt = clock.now

    discovery.cancel()

    await #expect(throws: CancellationError.self) {
      try await discovery.value
    }
    #expect(clock.now - cancelledAt < .milliseconds(500))
    #expect(await executor.currentState() == .disconnected)
    await executor.stop()
    #expect(await session.counts() == StallCounts(connects: 1, cancellations: 1))
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

  private struct StallCounts: Equatable, Sendable {
    let connects: Int
    let cancellations: Int
  }

  private struct SlowCleanupCounts: Equatable, Sendable {
    let connects: Int
    let cancellations: Int
  }

  private actor StallingSession: MCPClientSession {
    nonisolated let serverID: String
    private var shouldStall = true
    private var connects = 0
    private var cancellations = 0

    init(serverID: String) {
      self.serverID = serverID
    }

    func connect() async throws {
      connects += 1
      guard shouldStall else { return }
      do {
        try await Task.sleep(for: .seconds(60))
      } catch is CancellationError {
        cancellations += 1
        throw CancellationError()
      }
    }

    func disconnect() async {}

    func listTools() async throws -> [MCPRemoteTool] {
      [
        MCPRemoteTool(
          name: "echo",
          inputSchema: ["type": .string("object")]
        )
      ]
    }

    func callTool(_ call: MCPRemoteToolCall) async throws -> MCPRemoteToolResult {
      MCPRemoteToolResult(content: [.text(call.name)], isError: false)
    }

    func allowConnections() {
      shouldStall = false
    }

    func waitUntilConnectionStarts() async {
      while connects == 0 {
        await Task.yield()
      }
    }

    func counts() -> StallCounts {
      StallCounts(connects: connects, cancellations: cancellations)
    }
  }

  private actor SlowCancellationSession: MCPClientSession {
    nonisolated let serverID: String
    private var shouldStall = true
    private var cleanupReleased = false
    private var cleanupFinished = false
    private var connects = 0
    private var cancellations = 0

    init(serverID: String) {
      self.serverID = serverID
    }

    func connect() async throws {
      connects += 1
      guard shouldStall else { return }
      do {
        try await Task.sleep(for: .seconds(60))
      } catch is CancellationError {
        cancellations += 1
        while !cleanupReleased {
          await Task.yield()
        }
        cleanupFinished = true
        throw CancellationError()
      }
    }

    func disconnect() async {}

    func listTools() async throws -> [MCPRemoteTool] {
      [
        MCPRemoteTool(
          name: "echo",
          inputSchema: ["type": .string("object")]
        )
      ]
    }

    func callTool(_ call: MCPRemoteToolCall) async throws -> MCPRemoteToolResult {
      MCPRemoteToolResult(content: [.text(call.name)], isError: false)
    }

    func releaseCancellationCleanup() {
      shouldStall = false
      cleanupReleased = true
    }

    func cleanupDidFinish() -> Bool {
      cleanupFinished
    }

    func counts() -> SlowCleanupCounts {
      SlowCleanupCounts(connects: connects, cancellations: cancellations)
    }
  }
}
