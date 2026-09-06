import Foundation
import HexCore
import Testing

@testable import HexMCP

@Suite("MCP tool executor")
struct MCPToolExecutorTests {
  @Test("Publishes provider-portable names and routes normalized calls")
  func publishesProviderPortableNames() async throws {
    let session = FakeSession(
      serverID: "fixture",
      tools: [
        MCPRemoteTool(
          name: "inspect.window_state",
          description: "Inspect a window.",
          inputSchema: ["type": .string("object")]
        )
      ],
      result: MCPRemoteToolResult(content: [.text("window")], isError: false)
    )
    let executor = try MCPToolExecutor(sessions: [session])
    try await executor.start()

    let definition = try #require(await executor.availableTools().first)
    #expect(definition.name.utf8.count <= 64)
    #expect(
      definition.name.utf8.allSatisfy { byte in
        (0x30...0x39).contains(byte)
          || (0x41...0x5A).contains(byte)
          || (0x61...0x7A).contains(byte)
          || byte == 0x5F
          || byte == 0x2D
      }
    )

    _ = try await executor.execute(
      ToolCall(name: definition.name, arguments: [:]),
      in: ToolExecutionContext(runID: AgentRunID())
    )
    #expect(
      await session.receivedCalls() == [
        MCPRemoteToolCall(name: "inspect.window_state", arguments: [:])
      ]
    )
    await executor.stop()
  }

  @Test("Provider-portable aliases remain bounded and collision resistant")
  func providerPortableAliasesRemainBoundedAndDistinct() async throws {
    let remoteNames = [
      "inspect.window_state",
      "inspect_window_state",
      String(repeating: "a", count: 128),
    ]
    let session = FakeSession(
      serverID: "fixture",
      tools: remoteNames.map { name in
        MCPRemoteTool(name: name, inputSchema: ["type": .string("object")])
      },
      result: MCPRemoteToolResult(content: [.text("ok")], isError: false)
    )
    let executor = try MCPToolExecutor(sessions: [session])
    try await executor.start()

    let definitions = try await executor.availableTools()
    #expect(definitions.count == remoteNames.count)
    #expect(Set(definitions.map(\.name)).count == remoteNames.count)
    #expect(definitions.allSatisfy { $0.name.utf8.count <= 64 })

    for definition in definitions {
      _ = try await executor.execute(
        ToolCall(name: definition.name, arguments: [:]),
        in: ToolExecutionContext(runID: AgentRunID())
      )
    }
    #expect(Set(await session.receivedCalls().map(\.name)) == Set(remoteNames))
    await executor.stop()
  }

  @Test("Provider-portable aliases preserve the server and tool boundary")
  func providerPortableAliasesPreserveComponentBoundary() async throws {
    let underscoredServer = FakeSession(
      serverID: "a_b",
      tools: [MCPRemoteTool(name: "c", inputSchema: ["type": .string("object")])],
      result: MCPRemoteToolResult(content: [.text("first")], isError: false)
    )
    let underscoredTool = FakeSession(
      serverID: "a",
      tools: [MCPRemoteTool(name: "b_c", inputSchema: ["type": .string("object")])],
      result: MCPRemoteToolResult(content: [.text("second")], isError: false)
    )
    let executor = try MCPToolExecutor(sessions: [underscoredServer, underscoredTool])
    try await executor.start()

    let definitions = try await executor.availableTools()
    #expect(definitions.map(\.name) == ["mcp_1_a_b_c", "mcp_3_a_b_c"])
    for definition in definitions {
      _ = try await executor.execute(
        ToolCall(name: definition.name, arguments: [:]),
        in: ToolExecutionContext(runID: AgentRunID())
      )
    }
    #expect(await underscoredServer.receivedCalls().map(\.name) == ["c"])
    #expect(await underscoredTool.receivedCalls().map(\.name) == ["b_c"])
    await executor.stop()
  }

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
    #expect(definitions.map(\.name) == ["mcp_5_xcode_build_project"])

    let call = ToolCall(
      name: "mcp_5_xcode_build_project",
      arguments: ["scheme": .string("TOP_SECRET_SCHEME_ARGUMENT")]
    )
    let context = ToolExecutionContext(runID: AgentRunID())
    let authorization = try await executor.authorizationRequest(for: call, in: context)
    #expect(authorization.capability.rawValue == "mcp_5_xcode_build_project")
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
    let call = ToolCall(name: "mcp_7_fixture_inspect", arguments: [:])

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

  @Test("Omits required-task routes even when a custom session returns them")
  func omitsRequiredTaskRoutesFromCustomSessions() async throws {
    let session = FakeSession(
      serverID: "fixture",
      tools: [
        MCPRemoteTool(
          name: "long_job",
          inputSchema: ["type": .string("object")],
          taskSupport: .required,
          supportsTaskAugmentedToolCalls: true
        ),
        MCPRemoteTool(
          name: "ordinary_job",
          inputSchema: ["type": .string("object")]
        ),
      ],
      result: MCPRemoteToolResult(content: [.text("ordinary")], isError: false)
    )
    let executor = try MCPToolExecutor(sessions: [session])
    try await executor.start()

    #expect(try await executor.availableTools().map(\.name) == ["mcp_7_fixture_ordinary_job"])
    await #expect(throws: MCPToolExecutorError.unknownTool) {
      try await executor.execute(
        ToolCall(name: "mcp_7_fixture_long_job", arguments: [:]),
        in: ToolExecutionContext(runID: AgentRunID())
      )
    }
    #expect(await session.receivedCalls().isEmpty)
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
        ToolCall(name: "mcp_7_fixture_oversized", arguments: [:]),
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
    #expect(try await executor.availableTools().map(\.name) == ["mcp_5_gated_echo"])
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

  @Test("A completed concurrent stop batch leaves a restartable state")
  func concurrentStopCallersLeaveRestartableState() async throws {
    for iteration in 0..<32 {
      let session = GatedDisconnectSession(serverID: "gated-\(iteration)")
      let executor = try MCPToolExecutor(sessions: [session])
      try await executor.start()

      let firstStop = Task(priority: .background) {
        await executor.stop()
      }
      await session.waitUntilDisconnectStarts()
      let additionalStops = (0..<8).map { _ in
        Task(priority: .high) {
          await executor.stop()
        }
      }
      for _ in 0..<100 {
        await Task.yield()
      }

      await session.releaseDisconnect()
      await firstStop.value
      for stop in additionalStops {
        await stop.value
      }

      // A yield does not guarantee every stop task has entered the actor. Restart only after
      // the batch completes; otherwise a late stop is permitted to invalidate that new start.
      try await executor.start()
      #expect(await session.connectionCounts() == ConnectionCounts(connects: 2, disconnects: 1))
      await executor.stop()
    }
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
