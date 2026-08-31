import Foundation
import HexCore
import Testing

@testable import HexMCP

@Suite("MCP tool executor")
struct MCPToolExecutorTests {
  @Test("Publishes a cached namespaced catalog and routes exact remote calls")
  func publishesCatalogAndRoutesCalls() async throws {
    let session = FakeSession(
      serverID: "xcode",
      tools: [
        MCPRemoteTool(
          name: "build_project",
          description: "Build the selected Xcode project.",
          inputSchema: [
            "type": .string("object"),
            "properties": .object([:]),
          ]
        )
      ],
      result: MCPRemoteToolResult(
        content: [.text("Build succeeded")],
        structuredContent: .object(["warnings": .integer(0)]),
        isError: false
      )
    )
    let executor = try MCPToolExecutor(sessions: [session])

    #expect(try await executor.availableTools().isEmpty)
    try await executor.start()

    let definitions = try await executor.availableTools()
    #expect(definitions.map(\.name) == ["mcp.xcode.build_project"])

    let call = ToolCall(
      name: "mcp.xcode.build_project",
      arguments: ["scheme": .string("TOP_SECRET_SCHEME_ARGUMENT")]
    )
    let context = ToolExecutionContext(runID: AgentRunID())
    let authorization = try await executor.authorizationRequest(for: call, in: context)
    #expect(authorization.capability.rawValue == "mcp.xcode.build_project")
    #expect(authorization.resource == "mcp://xcode/build_project")
    #expect(!String(describing: authorization).contains("TOP_SECRET_SCHEME_ARGUMENT"))

    let result = try await executor.execute(call, in: context)
    #expect(result.toolCallID == call.id)
    #expect(result.status == .success)
    #expect(result.content == [.text("Build succeeded")])
    #expect(
      await session.receivedCalls() == [
        MCPRemoteToolCall(
          name: "build_project",
          arguments: ["scheme": .string("TOP_SECRET_SCHEME_ARGUMENT")]
        )
      ])
  }

  @Test("Maps bounded rich content and preserves remote failure status")
  func mapsRichContentAndFailureStatus() async throws {
    let imageURL = try #require(URL(string: "data:image/png;base64,AQ=="))
    let session = FakeSession(
      serverID: "fixture",
      tools: [
        MCPRemoteTool(
          name: "inspect",
          description: nil,
          inputSchema: ["type": .string("object")]
        )
      ],
      result: MCPRemoteToolResult(
        content: [
          .text("remote failure"),
          .image(data: "AQ==", mimeType: "image/png"),
          .audio(data: "Ag==", mimeType: "audio/mpeg"),
          .resourceLink(
            MCPResourceLink(
              name: "report",
              title: "Build report",
              uri: "file:///tmp/report.txt",
              description: "Local report",
              mimeType: "text/plain",
              size: 12
            )
          ),
          .resource(
            MCPEmbeddedResource(
              uri: "file:///tmp/details.txt",
              mimeType: "text/plain",
              text: "details",
              blob: nil
            )
          ),
        ],
        structuredContent: .object(["exitCode": .integer(1)]),
        isError: true
      )
    )
    let executor = try MCPToolExecutor(sessions: [session])
    try await executor.start()
    let call = ToolCall(name: "mcp.fixture.inspect", arguments: [:])

    let result = try await executor.execute(
      call,
      in: ToolExecutionContext(runID: AgentRunID())
    )

    #expect(result.status == .failure)
    #expect(
      result.content == [
        .text("remote failure"),
        .image(ImageContent(sourceURL: imageURL, mediaType: "image/png")),
        .text("[resource link report] file:///tmp/report.txt"),
        .text("[resource file:///tmp/details.txt]\ndetails"),
      ])
    let output = try #require(result.output.mcpObject)
    #expect(output["isError"] == .boolean(true))
    #expect(output["structuredContent"] == .object(["exitCode": .integer(1)]))
    #expect(output["content"]?.mcpArray?.count == 5)
    await executor.stop()
  }

  @Test("Rolls back connected sessions when a later startup step fails")
  func rollsBackFailedStartup() async throws {
    let first = LifecycleSession(serverID: "a", shouldFailConnect: false)
    let second = LifecycleSession(serverID: "b", shouldFailConnect: true)
    let executor = try MCPToolExecutor(sessions: [second, first])

    await #expect(throws: FixtureFailure.self) {
      try await executor.start()
    }
    #expect(await first.connectionCounts() == ConnectionCounts(connects: 1, disconnects: 1))
    #expect(await second.connectionCounts() == ConnectionCounts(connects: 1, disconnects: 0))
    #expect(try await executor.availableTools().isEmpty)

    await second.setShouldFailConnect(false)
    try await executor.start()
    await executor.stop()
    #expect(await first.connectionCounts() == ConnectionCounts(connects: 2, disconnects: 2))
    #expect(await second.connectionCounts() == ConnectionCounts(connects: 2, disconnects: 1))
  }

  @Test("Stopping an in-flight startup cancels it and leaves no catalog")
  func stopDuringStartup() async throws {
    let session = SlowConnectSession(serverID: "slow")
    let executor = try MCPToolExecutor(sessions: [session])
    let startTask = Task {
      try await executor.start()
    }
    await session.waitUntilConnectStarts()

    async let firstStop: Void = executor.stop()
    async let secondStop: Void = executor.stop()
    _ = await (firstStop, secondStop)

    await #expect(throws: CancellationError.self) {
      try await startTask.value
    }
    #expect(try await executor.availableTools().isEmpty)
  }

  @Test("Rejects aggregate result content before duplicating an oversized result")
  func rejectsOversizedAggregateResult() async throws {
    let chunk = String(repeating: "x", count: 800 * 1_024)
    let session = FakeSession(
      serverID: "fixture",
      tools: [
        MCPRemoteTool(
          name: "oversized",
          description: nil,
          inputSchema: ["type": .string("object")]
        )
      ],
      result: MCPRemoteToolResult(
        content: [.text(chunk), .text(chunk), .text(chunk)],
        isError: false
      )
    )
    let executor = try MCPToolExecutor(sessions: [session])
    try await executor.start()

    await #expect(throws: MCPToolExecutorError.invalidToolResult) {
      try await executor.execute(
        ToolCall(name: "mcp.fixture.oversized", arguments: [:]),
        in: ToolExecutionContext(runID: AgentRunID())
      )
    }
    await executor.stop()
  }

  @Test("Startup commits atomically after its initial cancellation boundary")
  func cancelledStartupWaiterDoesNotLeak() async throws {
    let session = GatedCatalogSession(serverID: "gated")
    let executor = try MCPToolExecutor(sessions: [session])
    let cancelledWaiter = Task {
      try await executor.start()
    }
    await session.waitUntilCatalogStarts()
    let successfulWaiter = Task {
      try await executor.start()
    }
    await Task.yield()
    cancelledWaiter.cancel()
    await session.releaseCatalog()

    try await cancelledWaiter.value
    try await successfulWaiter.value
    #expect(try await executor.availableTools().map(\.name) == ["mcp.gated.echo"])
    #expect(await session.connectionCounts() == ConnectionCounts(connects: 1, disconnects: 0))

    await executor.stop()
    #expect(await session.connectionCounts() == ConnectionCounts(connects: 1, disconnects: 1))
  }

  @Test("Concurrent stop callers wait for the same completed disconnect")
  func concurrentStopCallersWaitForDisconnect() async throws {
    let session = GatedDisconnectSession(serverID: "gated")
    let executor = try MCPToolExecutor(sessions: [session])
    let completions = CompletionProbe()
    try await executor.start()

    let firstStop = Task {
      await executor.stop()
      await completions.markCompleted()
    }
    await session.waitUntilDisconnectStarts()
    let secondStop = Task {
      await executor.stop()
      await completions.markCompleted()
    }
    for _ in 0..<20 {
      await Task.yield()
    }
    #expect(await completions.count() == 0)

    await session.releaseDisconnect()
    await firstStop.value
    await secondStop.value
    #expect(await completions.count() == 2)
    #expect(await session.connectionCounts() == ConnectionCounts(connects: 1, disconnects: 1))
  }

  actor FakeSession: MCPClientSession {
    nonisolated let serverID: String
    private let tools: [MCPRemoteTool]
    private let result: MCPRemoteToolResult
    private var calls: [MCPRemoteToolCall] = []

    init(
      serverID: String,
      tools: [MCPRemoteTool],
      result: MCPRemoteToolResult
    ) {
      self.serverID = serverID
      self.tools = tools
      self.result = result
    }

    func connect() async throws {}

    func disconnect() async {}

    func listTools() async throws -> [MCPRemoteTool] {
      tools
    }

    func callTool(_ call: MCPRemoteToolCall) async throws -> MCPRemoteToolResult {
      calls.append(call)
      return result
    }

    func receivedCalls() -> [MCPRemoteToolCall] {
      calls
    }
  }

  struct ConnectionCounts: Equatable, Sendable {
    let connects: Int
    let disconnects: Int
  }

  enum FixtureFailure: Error {
    case connect
  }

  actor LifecycleSession: MCPClientSession {
    nonisolated let serverID: String
    private var shouldFailConnect: Bool
    private var connects = 0
    private var disconnects = 0

    init(serverID: String, shouldFailConnect: Bool) {
      self.serverID = serverID
      self.shouldFailConnect = shouldFailConnect
    }

    func connect() async throws {
      connects += 1
      if shouldFailConnect {
        throw FixtureFailure.connect
      }
    }

    func disconnect() async {
      disconnects += 1
    }

    func listTools() async throws -> [MCPRemoteTool] {
      []
    }

    func callTool(_ call: MCPRemoteToolCall) async throws -> MCPRemoteToolResult {
      _ = call
      throw FixtureFailure.connect
    }

    func setShouldFailConnect(_ value: Bool) {
      shouldFailConnect = value
    }

    func connectionCounts() -> ConnectionCounts {
      ConnectionCounts(connects: connects, disconnects: disconnects)
    }
  }

  actor SlowConnectSession: MCPClientSession {
    nonisolated let serverID: String
    private var connectStarted = false

    init(serverID: String) {
      self.serverID = serverID
    }

    func connect() async throws {
      connectStarted = true
      try await Task.sleep(for: .seconds(60))
    }

    func disconnect() async {}

    func listTools() async throws -> [MCPRemoteTool] {
      []
    }

    func callTool(_ call: MCPRemoteToolCall) async throws -> MCPRemoteToolResult {
      _ = call
      throw FixtureFailure.connect
    }

    func waitUntilConnectStarts() async {
      while !connectStarted {
        await Task.yield()
      }
    }
  }

  actor GatedCatalogSession: MCPClientSession {
    nonisolated let serverID: String
    private var connects = 0
    private var disconnects = 0
    private var catalogStarted = false
    private var catalogReleased = false

    init(serverID: String) {
      self.serverID = serverID
    }

    func connect() async throws {
      connects += 1
    }

    func disconnect() async {
      disconnects += 1
    }

    func listTools() async throws -> [MCPRemoteTool] {
      catalogStarted = true
      while !catalogReleased {
        await Task.yield()
      }
      return [
        MCPRemoteTool(
          name: "echo",
          description: nil,
          inputSchema: ["type": .string("object")]
        )
      ]
    }

    func callTool(_ call: MCPRemoteToolCall) async throws -> MCPRemoteToolResult {
      _ = call
      return MCPRemoteToolResult(content: [], isError: false)
    }

    func waitUntilCatalogStarts() async {
      while !catalogStarted {
        await Task.yield()
      }
    }

    func releaseCatalog() {
      catalogReleased = true
    }

    func connectionCounts() -> ConnectionCounts {
      ConnectionCounts(connects: connects, disconnects: disconnects)
    }
  }

  actor GatedDisconnectSession: MCPClientSession {
    nonisolated let serverID: String
    private var connects = 0
    private var disconnects = 0
    private var disconnectStarted = false
    private var disconnectReleased = false

    init(serverID: String) {
      self.serverID = serverID
    }

    func connect() async throws {
      connects += 1
    }

    func disconnect() async {
      disconnectStarted = true
      while !disconnectReleased {
        await Task.yield()
      }
      disconnects += 1
    }

    func listTools() async throws -> [MCPRemoteTool] {
      []
    }

    func callTool(_ call: MCPRemoteToolCall) async throws -> MCPRemoteToolResult {
      _ = call
      return MCPRemoteToolResult(content: [], isError: false)
    }

    func waitUntilDisconnectStarts() async {
      while !disconnectStarted {
        await Task.yield()
      }
    }

    func releaseDisconnect() {
      disconnectReleased = true
    }

    func connectionCounts() -> ConnectionCounts {
      ConnectionCounts(connects: connects, disconnects: disconnects)
    }
  }

  actor CompletionProbe {
    private var completed = 0

    func markCompleted() {
      completed += 1
    }

    func count() -> Int {
      completed
    }
  }
}
