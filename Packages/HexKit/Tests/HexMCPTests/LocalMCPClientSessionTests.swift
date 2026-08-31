import Foundation
import HexCore
import Testing

@testable import HexMCP

@Suite("Local MCP client session")
struct LocalMCPClientSessionTests {
  @Test("Negotiates, paginates tools, and calls a remote tool")
  func negotiatesPaginatesAndCalls() async throws {
    let connection = ScriptedConnection(
      responses: [
        .object([
          "protocolVersion": .string("2025-06-18"),
          "capabilities": .object(["tools": .object([:])]),
          "serverInfo": .object([
            "name": .string("Xcode"),
            "version": .string("26.4"),
          ]),
        ]),
        .object([
          "tools": .array([
            .object([
              "name": .string("build_project"),
              "description": .string("Build the selected project."),
              "inputSchema": .object(["type": .string("object")]),
            ])
          ]),
          "nextCursor": .string("page-2"),
        ]),
        .object([
          "tools": .array([
            .object([
              "name": .string("read_issues"),
              "inputSchema": .object(["type": .string("object")]),
            ])
          ])
        ]),
        .object([
          "content": .array([
            .object(["type": .string("text"), "text": .string("Build succeeded")])
          ]),
          "structuredContent": .object(["warnings": .integer(0)]),
          "isError": .boolean(false),
        ]),
      ]
    )
    let session = LocalMCPClientSession(
      configuration: try configuration(),
      connection: connection
    )

    try await session.connect()
    let tools = try await session.listTools()
    let result = try await session.callTool(
      MCPRemoteToolCall(
        name: "build_project",
        arguments: ["scheme": .string("Hex")]
      )
    )

    #expect(tools.map(\.name) == ["build_project", "read_issues"])
    #expect(result.content == [.text("Build succeeded")])
    #expect(result.structuredContent == .object(["warnings": .integer(0)]))
    #expect(
      await connection.methods() == [
        "initialize",
        "notifications/initialized",
        "tools/list",
        "tools/list",
        "tools/call",
      ])
    #expect(
      await connection.parameters(for: "tools/list").last
        == .object(["cursor": .string("page-2")])
    )
  }

  @Test("Rejects unsupported negotiated versions and tears down the connection")
  func rejectsUnsupportedVersion() async throws {
    let connection = ScriptedConnection(
      responses: [
        .object([
          "protocolVersion": .string("2099-01-01"),
          "capabilities": .object(["tools": .object([:])]),
          "serverInfo": .object([
            "name": .string("Future"),
            "version": .string("1"),
          ]),
        ])
      ]
    )
    let session = LocalMCPClientSession(
      configuration: try configuration(),
      connection: connection
    )

    await #expect(throws: MCPClientSessionError.unsupportedProtocolVersion) {
      try await session.connect()
    }
    #expect(await connection.disconnectCount() == 1)
  }

  @Test("Rejects duplicate tool names across catalog pages")
  func rejectsDuplicateToolNamesAcrossPages() async throws {
    let connection = ScriptedConnection(
      responses: [
        initializationResponse(),
        toolPage(name: "echo", nextCursor: "page-2"),
        toolPage(name: "echo", nextCursor: nil),
      ]
    )
    let session = LocalMCPClientSession(
      configuration: try configuration(),
      connection: connection
    )
    try await session.connect()

    await #expect(throws: MCPClientSessionError.protocolViolation) {
      try await session.listTools()
    }
    #expect(await connection.disconnectCount() == 1)
  }

  @Test("Rejects cyclic catalog cursors")
  func rejectsCyclicCatalogCursors() async throws {
    let connection = ScriptedConnection(
      responses: [
        initializationResponse(),
        toolPage(name: "first", nextCursor: "same"),
        toolPage(name: "second", nextCursor: "same"),
      ]
    )
    let session = LocalMCPClientSession(
      configuration: try configuration(),
      connection: connection
    )
    try await session.connect()

    await #expect(throws: MCPClientSessionError.protocolViolation) {
      try await session.listTools()
    }
    #expect(await connection.disconnectCount() == 1)
  }

  @Test("Rejects non-object structured tool content")
  func rejectsNonObjectStructuredContent() async throws {
    let connection = ScriptedConnection(
      responses: [
        initializationResponse(),
        .object([
          "content": .array([]),
          "structuredContent": .array([.string("not an object")]),
          "isError": .boolean(false),
        ]),
      ]
    )
    let session = LocalMCPClientSession(
      configuration: try configuration(),
      connection: connection
    )
    try await session.connect()

    await #expect(throws: MCPClientSessionError.protocolViolation) {
      try await session.callTool(MCPRemoteToolCall(name: "echo", arguments: [:]))
    }
    #expect(await connection.disconnectCount() == 1)
  }

  @Test("Invalidates the session when a catalog page is malformed")
  func invalidatesMalformedCatalogPage() async throws {
    let connection = ScriptedConnection(
      responses: [
        initializationResponse(),
        .object([
          "tools": .array([
            .object([
              "name": .string("missing_schema")
            ])
          ])
        ]),
      ]
    )
    let session = LocalMCPClientSession(
      configuration: try configuration(),
      connection: connection
    )
    try await session.connect()

    await #expect(throws: MCPClientSessionError.protocolViolation) {
      try await session.listTools()
    }
    #expect(await connection.disconnectCount() == 1)
  }

  @Test("Withholds required-task tools and rejects a direct call without writing it")
  func withholdsRequiredTaskTools() async throws {
    let connection = ScriptedConnection(
      responses: [
        initializationResponse(
          protocolVersion: "2025-11-25",
          supportsTaskToolCalls: true
        ),
        toolPage(name: "long_job", taskSupport: "required"),
      ]
    )
    let session = LocalMCPClientSession(
      configuration: try configuration(),
      connection: connection
    )
    try await session.connect()

    #expect(await session.initialization?.supportsTaskAugmentedToolCalls == true)
    let tools = try await session.listTools()
    #expect(tools.isEmpty)
    await #expect(throws: MCPClientSessionError.toolsUnavailable) {
      try await session.callTool(MCPRemoteToolCall(name: "long_job", arguments: [:]))
    }
    #expect(!(await connection.methods()).contains("tools/call"))
  }

  @Test("Rejects direct 2025-11 task-capable calls before discovery")
  func rejectsTaskCapableCallBeforeDiscovery() async throws {
    let connection = ScriptedConnection(
      responses: [
        initializationResponse(
          protocolVersion: "2025-11-25",
          supportsTaskToolCalls: true
        )
      ]
    )
    let session = LocalMCPClientSession(
      configuration: try configuration(),
      connection: connection
    )
    try await session.connect()

    await #expect(throws: MCPClientSessionError.toolsUnavailable) {
      try await session.callTool(MCPRemoteToolCall(name: "unknown_job", arguments: [:]))
    }
    #expect(!(await connection.methods()).contains("tools/call"))
  }

  @Test("Rejects malformed negotiated task-call capability shapes")
  func rejectsMalformedTaskCapability() async throws {
    let connection = ScriptedConnection(
      responses: [
        .object([
          "protocolVersion": .string("2025-11-25"),
          "capabilities": .object([
            "tools": .object([:]),
            "tasks": .object([
              "requests": .object([
                "tools": .object([
                  "call": .boolean(true)
                ])
              ])
            ]),
          ]),
          "serverInfo": .object([
            "name": .string("Fixture"),
            "version": .string("1"),
          ]),
        ])
      ]
    )
    let session = LocalMCPClientSession(
      configuration: try configuration(),
      connection: connection
    )

    await #expect(throws: MCPClientSessionError.protocolViolation) {
      try await session.connect()
    }
    #expect(await connection.disconnectCount() == 1)
  }

  @Test("Keeps optional and ordinary 2025-11 tools callable without task augmentation")
  func callsOptionalAndOrdinaryToolsNormally() async throws {
    let connection = ScriptedConnection(
      responses: [
        initializationResponse(
          protocolVersion: "2025-11-25",
          supportsTaskToolCalls: true
        ),
        .object([
          "tools": .array([
            tool(name: "optional_job", taskSupport: "optional"),
            tool(name: "ordinary_job"),
          ])
        ]),
        toolResult(text: "optional"),
        toolResult(text: "ordinary"),
      ]
    )
    let session = LocalMCPClientSession(
      configuration: try configuration(),
      connection: connection
    )
    try await session.connect()

    let tools = try await session.listTools()
    #expect(tools.map(\.name) == ["optional_job", "ordinary_job"])
    let optional = try await session.callTool(
      MCPRemoteToolCall(name: "optional_job", arguments: [:])
    )
    let ordinary = try await session.callTool(
      MCPRemoteToolCall(name: "ordinary_job", arguments: [:])
    )

    #expect(optional.content == [.text("optional")])
    #expect(ordinary.content == [.text("ordinary")])
    #expect(
      await connection.parameters(for: "tools/call") == [
        .object([
          "name": .string("optional_job"),
          "arguments": .object([:]),
        ]),
        .object([
          "name": .string("ordinary_job"),
          "arguments": .object([:]),
        ]),
      ])
  }

  @Test("Rejects unknown task-support metadata without publishing the tool")
  func rejectsUnknownTaskSupport() async throws {
    let connection = ScriptedConnection(
      responses: [
        initializationResponse(
          protocolVersion: "2025-11-25",
          supportsTaskToolCalls: true
        ),
        toolPage(name: "future_job", taskSupport: "future-mode"),
      ]
    )
    let session = LocalMCPClientSession(
      configuration: try configuration(),
      connection: connection
    )
    try await session.connect()

    await #expect(throws: MCPClientSessionError.protocolViolation) {
      try await session.listTools()
    }
    #expect(await connection.disconnectCount() == 1)
  }

  @Test("Treats task metadata as non-task when task calls were not negotiated")
  func callsRequiredMarkerNormallyWithoutTaskCapability() async throws {
    let connection = ScriptedConnection(
      responses: [
        initializationResponse(protocolVersion: "2025-11-25"),
        toolPage(name: "ordinary_job", taskSupport: "required"),
        toolResult(text: "ordinary"),
      ]
    )
    let session = LocalMCPClientSession(
      configuration: try configuration(),
      connection: connection
    )
    try await session.connect()

    let tools = try await session.listTools()
    #expect(tools.map(\.name) == ["ordinary_job"])
    let result = try await session.callTool(
      MCPRemoteToolCall(name: "ordinary_job", arguments: [:])
    )

    #expect(result.content == [.text("ordinary")])
  }

  @Test("Runs the public session and tool executor through a real stdio server")
  func publicSessionEndToEnd() async throws {
    let program =
      #"index($0, "\"method\":\"initialize\"") { print "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"Fixture\",\"version\":\"1\"}}}"; fflush(); next } index($0, "\"method\":\"tools/list\"") { print "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"echo\",\"description\":\"Echo locally.\",\"inputSchema\":{\"type\":\"object\"}}]}}"; fflush(); next } index($0, "\"method\":\"tools/call\"") { print "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"hello from MCP\"}],\"isError\":false}}"; fflush(); next }"#
    let configuration = try MCPServerConfiguration(
      serverID: "fixture",
      executableURL: URL(fileURLWithPath: "/usr/bin/awk"),
      arguments: [program],
      workingDirectory: URL(fileURLWithPath: "/"),
      environment: ["PATH": "/usr/bin:/bin"],
      requestTimeoutMilliseconds: 2_000,
      shutdownGraceMilliseconds: 50,
      maximumMessageBytes: 4 * 1_024
    )
    let session = LocalMCPClientSession(configuration: configuration)
    let executor = try MCPToolExecutor(sessions: [session])

    try await executor.start()
    let definitions = try await executor.availableTools()
    #expect(definitions.map(\.name) == ["mcp.fixture.echo"])

    let call = ToolCall(
      name: "mcp.fixture.echo",
      arguments: ["text": .string("hello")]
    )
    let result = try await executor.execute(
      call,
      in: ToolExecutionContext(runID: AgentRunID())
    )
    #expect(result.status == .success)
    #expect(result.content == [.text("hello from MCP")])
    await executor.stop()
  }

  @Test("Enforces negotiated task requirements through a real stdio server")
  func requiredTaskToolIsUnavailableEndToEnd() async throws {
    let program =
      #"index($0, "\"method\":\"initialize\"") { print "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"tools\":{},\"tasks\":{\"requests\":{\"tools\":{\"call\":{}}}}},\"serverInfo\":{\"name\":\"Fixture\",\"version\":\"1\"}}}"; fflush(); next } index($0, "\"method\":\"tools/list\"") { print "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"long_job\",\"inputSchema\":{\"type\":\"object\"},\"execution\":{\"taskSupport\":\"required\"}},{\"name\":\"ordinary_job\",\"inputSchema\":{\"type\":\"object\"}}]}}"; fflush(); next } index($0, "\"method\":\"tools/call\"") { print "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ordinary\"}],\"isError\":false}}"; fflush(); next }"#
    let configuration = try MCPServerConfiguration(
      serverID: "fixture",
      executableURL: URL(fileURLWithPath: "/usr/bin/awk"),
      arguments: [program],
      workingDirectory: URL(fileURLWithPath: "/"),
      environment: ["PATH": "/usr/bin:/bin"],
      requestTimeoutMilliseconds: 2_000,
      shutdownGraceMilliseconds: 50,
      maximumMessageBytes: 4 * 1_024
    )
    let session = LocalMCPClientSession(configuration: configuration)
    let executor = try MCPToolExecutor(sessions: [session])
    try await executor.start()

    #expect(try await executor.availableTools().map(\.name) == ["mcp.fixture.ordinary_job"])
    await #expect(throws: MCPClientSessionError.toolsUnavailable) {
      try await session.callTool(MCPRemoteToolCall(name: "long_job", arguments: [:]))
    }
    let result = try await executor.execute(
      ToolCall(name: "mcp.fixture.ordinary_job", arguments: [:]),
      in: ToolExecutionContext(runID: AgentRunID())
    )

    #expect(result.status == .success)
    #expect(result.content == [.text("ordinary")])
    await executor.stop()
  }

  private func configuration() throws -> MCPServerConfiguration {
    try MCPServerConfiguration(
      serverID: "xcode",
      executableURL: URL(fileURLWithPath: "/usr/bin/true"),
      arguments: [],
      workingDirectory: URL(fileURLWithPath: "/"),
      environment: ["PATH": "/usr/bin:/bin"]
    )
  }

  private func initializationResponse(
    protocolVersion: String = "2025-06-18",
    supportsTaskToolCalls: Bool = false
  ) -> JSONValue {
    var capabilities: [String: JSONValue] = ["tools": .object([:])]
    if supportsTaskToolCalls {
      capabilities["tasks"] = .object([
        "requests": .object([
          "tools": .object([
            "call": .object([:])
          ])
        ])
      ])
    }
    return .object([
      "protocolVersion": .string(protocolVersion),
      "capabilities": .object(capabilities),
      "serverInfo": .object([
        "name": .string("Fixture"),
        "version": .string("1"),
      ]),
    ])
  }

  private func toolPage(name: String, nextCursor: String?) -> JSONValue {
    var page: [String: JSONValue] = [
      "tools": .array([
        .object([
          "name": .string(name),
          "inputSchema": .object(["type": .string("object")]),
        ])
      ])
    ]
    if let nextCursor {
      page["nextCursor"] = .string(nextCursor)
    }
    return .object(page)
  }

  private func toolPage(name: String, taskSupport: String) -> JSONValue {
    .object([
      "tools": .array([
        tool(name: name, taskSupport: taskSupport)
      ])
    ])
  }

  private func tool(name: String, taskSupport: String? = nil) -> JSONValue {
    var object: [String: JSONValue] = [
      "name": .string(name),
      "inputSchema": .object(["type": .string("object")]),
    ]
    if let taskSupport {
      object["execution"] = .object([
        "taskSupport": .string(taskSupport)
      ])
    }
    return .object(object)
  }

  private func toolResult(text: String) -> JSONValue {
    .object([
      "content": .array([
        .object([
          "type": .string("text"),
          "text": .string(text),
        ])
      ]),
      "isError": .boolean(false),
    ])
  }

  actor ScriptedConnection: MCPJSONRPCConnection {
    private var responses: [JSONValue]
    private var recordedMethods: [String] = []
    private var recordedParameters: [(String, JSONValue)] = []
    private var disconnects = 0

    init(responses: [JSONValue]) {
      self.responses = responses
    }

    func connect() async throws {}

    func disconnect() async {
      disconnects += 1
    }

    func request(method: String, params: JSONValue) async throws -> JSONValue {
      recordedMethods.append(method)
      recordedParameters.append((method, params))
      guard !responses.isEmpty else {
        throw MCPClientSessionError.protocolViolation
      }
      return responses.removeFirst()
    }

    func notify(method: String, params: JSONValue?) async throws {
      _ = params
      recordedMethods.append(method)
    }

    func methods() -> [String] {
      recordedMethods
    }

    func parameters(for method: String) -> [JSONValue] {
      recordedParameters.compactMap { recordedMethod, parameters in
        recordedMethod == method ? parameters : nil
      }
    }

    func disconnectCount() -> Int {
      disconnects
    }
  }
}
