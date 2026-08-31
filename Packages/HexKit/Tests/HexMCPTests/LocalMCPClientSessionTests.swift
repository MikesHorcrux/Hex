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

  private func configuration() throws -> MCPServerConfiguration {
    try MCPServerConfiguration(
      serverID: "xcode",
      executableURL: URL(fileURLWithPath: "/usr/bin/true"),
      arguments: [],
      workingDirectory: URL(fileURLWithPath: "/"),
      environment: ["PATH": "/usr/bin:/bin"]
    )
  }

  private func initializationResponse() -> JSONValue {
    .object([
      "protocolVersion": .string("2025-06-18"),
      "capabilities": .object(["tools": .object([:])]),
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
