import HexCore
import Testing

@testable import HexMCP

@Suite("Managed MCP cached health")
struct MCPManagedToolExecutorHealthTests {
  @Test("Health inspection never connects or discovers tools")
  func readingHealthHasNoConnectionSideEffects() async throws {
    let session = Session()
    let executor = try MCPManagedToolExecutor(session: session)

    for _ in 0..<20 {
      #expect(
        await executor.healthSnapshot()
          == MCPManagedToolExecutorSnapshot(serverID: "fixture", state: .disconnected))
    }
    #expect(await session.counts() == Counts(connects: 0, lists: 0))
    await executor.stop()
  }

  @Test("A stalled startup reports its deadline rather than an unspecified connection failure")
  func startupTimeoutIsDistinguishable() async throws {
    let session = Session(stalls: true)
    let executor = try MCPManagedToolExecutor(
      session: session, startupTimeout: .milliseconds(100))

    #expect(try await executor.availableTools().isEmpty)
    let timedOut = await executor.healthSnapshot()
    #expect(timedOut.state == .unavailable)
    #expect(timedOut.failure == .connectionTimedOut)
    #expect(timedOut.availableToolCount == nil)
    // Inspecting the failure cannot defeat its cooldown or start another connection.
    #expect(await executor.healthSnapshot() == timedOut)
    #expect(await session.counts() == Counts(connects: 1, lists: 0))

    await executor.stop()
    #expect(
      await executor.healthSnapshot()
        == MCPManagedToolExecutorSnapshot(serverID: "fixture", state: .disconnected))
  }

  @Test("A deferred missing managed installation has a specific sanitized category")
  func missingManagedComponentIsDistinguishable() async throws {
    let session = try MCPDeferredClientSession(serverID: "fixture") {
      throw MCPManagedToolLayoutError.invalidInstallation(.playwright)
    }
    let executor = try MCPManagedToolExecutor(session: session)

    #expect(try await executor.availableTools().isEmpty)
    #expect(
      await executor.healthSnapshot()
        == MCPManagedToolExecutorSnapshot(
          serverID: "fixture", state: .unavailable, failure: .componentMissing))
    await executor.stop()
  }

  @Test(
    "Ready health uses the validated cached count and refresh failures replace it",
    arguments: [0, 2])
  func cachedReadyCountAndRefreshFailure(initialCount: Int) async throws {
    let session = Session(toolCount: initialCount)
    let executor = try MCPManagedToolExecutor(session: session)
    #expect(try await executor.availableTools().count == initialCount)

    for _ in 0..<10 {
      #expect(
        await executor.healthSnapshot()
          == MCPManagedToolExecutorSnapshot(
            serverID: "fixture", state: .ready, availableToolCount: initialCount))
    }
    #expect(await session.counts() == Counts(connects: 1, lists: 1))

    await session.setToolCount(3)
    try await executor.refreshCatalog()
    #expect(await executor.healthSnapshot().availableToolCount == 3)
    #expect(await session.counts() == Counts(connects: 1, lists: 2))

    await session.rejectCatalog()
    await #expect(throws: MCPClientSessionError.protocolViolation) {
      try await executor.refreshCatalog()
    }
    #expect(
      await executor.healthSnapshot()
        == MCPManagedToolExecutorSnapshot(
          serverID: "fixture", state: .unavailable, failure: .invalidResponse))
    #expect(await session.counts() == Counts(connects: 1, lists: 3))
    await executor.stop()
    #expect(
      await executor.healthSnapshot()
        == MCPManagedToolExecutorSnapshot(serverID: "fixture", state: .disconnected))
  }

  @Test(
    "Typed startup errors expose categories, never raw error payloads", arguments: Failure.allCases)
  func startupErrorsAreSanitized(failure: Failure) async throws {
    let session = Session(failure: failure)
    let executor = try MCPManagedToolExecutor(session: session)
    #expect(try await executor.availableTools().isEmpty)
    #expect(
      await executor.healthSnapshot()
        == MCPManagedToolExecutorSnapshot(
          serverID: "fixture", state: .unavailable, failure: failure.expectedCategory))
    await executor.stop()
  }

  enum Failure: CaseIterable, Sendable {
    case configuration
    case serverRejection
    case invalidResponse
    case unknown

    var error: any Error {
      switch self {
      case .configuration: MCPServerConfigurationError.invalidEnvironment
      case .serverRejection: MCPClientSessionError.remoteError(code: -32_000)
      case .invalidResponse: MCPToolExecutorError.invalidToolDefinition
      case .unknown:
        UnknownFailure(privateDetails: "private endpoint, environment, and server output")
      }
    }

    var expectedCategory: MCPManagedToolFailure {
      switch self {
      case .configuration: .configurationInvalid
      case .serverRejection: .serverRejected
      case .invalidResponse: .invalidResponse
      case .unknown: .connectionFailed
      }
    }
  }

  private struct UnknownFailure: Error {
    let privateDetails: String
  }

  private struct Counts: Equatable, Sendable {
    let connects: Int
    let lists: Int
  }

  private actor Session: MCPClientSession {
    nonisolated let serverID = "fixture"
    private let stalls: Bool
    private let failure: Failure?
    private var toolCount: Int
    private var rejectsCatalog = false
    private var connects = 0
    private var lists = 0

    init(stalls: Bool = false, toolCount: Int = 1, failure: Failure? = nil) {
      self.stalls = stalls
      self.toolCount = toolCount
      self.failure = failure
    }

    func connect() async throws {
      connects += 1
      if let failure { throw failure.error }
      if stalls { try await Task.sleep(for: .seconds(60)) }
    }

    func disconnect() async {}

    func listTools() async throws -> [MCPRemoteTool] {
      lists += 1
      if rejectsCatalog { throw MCPClientSessionError.protocolViolation }
      return (0..<toolCount).map { index in
        MCPRemoteTool(name: "echo\(index)", inputSchema: ["type": .string("object")])
      }
    }

    func callTool(_ call: MCPRemoteToolCall) async throws -> MCPRemoteToolResult {
      MCPRemoteToolResult(content: [.text(call.name)], isError: false)
    }

    func setToolCount(_ count: Int) { toolCount = count }

    func rejectCatalog() { rejectsCatalog = true }

    func counts() -> Counts { Counts(connects: connects, lists: lists) }
  }
}
