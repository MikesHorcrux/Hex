import Foundation
import HexCore
import Testing

@testable import HexMCP

@Suite("Streamable HTTP MCP client session")
struct StreamableHTTPMCPClientSessionTests {
  @Test("Negotiates a session, decodes SSE discovery, and calls a tool")
  func negotiatesDiscoversAndCalls() async throws {
    let endpoint = try #require(URL(string: "https://mcp.example.com/v1"))
    let transport = StubTransport(
      responses: [
        try Self.response(
          endpoint: endpoint,
          id: 1,
          result: Self.initializationResult(),
          headers: ["mcp-session-id": "session-1"]
        ),
        Self.accepted(endpoint: endpoint),
        try Self.eventStreamResponse(
          endpoint: endpoint,
          id: 2,
          result: .object([
            "tools": .array([
              .object([
                "name": .string("echo"),
                "description": .string("Echo text."),
                "inputSchema": .object(["type": .string("object")]),
              ])
            ])
          ])
        ),
        try Self.response(
          endpoint: endpoint,
          id: 3,
          result: .object([
            "content": .array([
              .object(["type": .string("text"), "text": .string("hello")])
            ]),
            "isError": .boolean(false),
          ])
        ),
      ]
    )
    let session = StreamableHTTPMCPClientSession(
      configuration: try MCPStreamableHTTPServerConfiguration(
        serverID: "remote",
        endpointURL: endpoint
      ),
      headerProvider: StaticHeaderProvider(headers: ["Authorization": "Bearer test"]),
      transport: transport
    )

    try await session.connect()
    let tools = try await session.listTools()
    let result = try await session.callTool(
      MCPRemoteToolCall(name: "echo", arguments: ["text": .string("hello")])
    )

    #expect(tools.map { $0.name } == ["echo"])
    #expect(result.content == [MCPToolContent.text("hello")])
    let requests = await transport.requests()
    #expect(requests.count == 4)
    #expect(requests[0].value(forHTTPHeaderField: "MCP-Session-Id") == nil)
    #expect(requests[0].value(forHTTPHeaderField: "MCP-Protocol-Version") == nil)
    for request in requests {
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test")
    }
    for request in requests.dropFirst() {
      #expect(request.value(forHTTPHeaderField: "MCP-Session-Id") == "session-1")
      #expect(request.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2025-11-25")
    }
  }

  @Test("Rejects caller overrides of transport-owned headers")
  func rejectsReservedHeaders() async throws {
    let endpoint = try #require(URL(string: "https://mcp.example.com"))
    let transport = StubTransport(responses: [])
    let session = StreamableHTTPMCPClientSession(
      configuration: try MCPStreamableHTTPServerConfiguration(
        serverID: "remote",
        endpointURL: endpoint
      ),
      headerProvider: StaticHeaderProvider(headers: ["MCP-Session-Id": "attacker"]),
      transport: transport
    )

    await #expect(throws: MCPClientSessionError.protocolViolation) {
      try await session.connect()
    }
    let requests = await transport.requests()
    #expect(requests.isEmpty)
  }

  private static func initializationResult() -> JSONValue {
    .object([
      "protocolVersion": .string("2025-11-25"),
      "capabilities": .object(["tools": .object([:])]),
      "serverInfo": .object([
        "name": .string("Fixture"),
        "version": .string("1"),
      ]),
    ])
  }

  private static func response(
    endpoint: URL,
    id: Int64,
    result: JSONValue,
    headers: [String: String] = [:]
  ) throws -> MCPHTTPResponse {
    var resolvedHeaders = headers
    resolvedHeaders["content-type"] = "application/json"
    return MCPHTTPResponse(
      statusCode: 200,
      headers: resolvedHeaders,
      body: try JSONEncoder().encode(
        JSONValue.object([
          "jsonrpc": .string("2.0"),
          "id": .integer(id),
          "result": result,
        ])
      ),
      finalURL: endpoint
    )
  }

  private static func eventStreamResponse(
    endpoint: URL,
    id: Int64,
    result: JSONValue
  ) throws -> MCPHTTPResponse {
    let data = try JSONEncoder().encode(
      JSONValue.object([
        "jsonrpc": .string("2.0"),
        "id": .integer(id),
        "result": result,
      ])
    )
    let eventStream = ": keepalive\n\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
    return MCPHTTPResponse(
      statusCode: 200,
      headers: ["content-type": "text/event-stream; charset=utf-8"],
      body: Data(eventStream.utf8),
      finalURL: endpoint
    )
  }

  private static func accepted(endpoint: URL) -> MCPHTTPResponse {
    MCPHTTPResponse(statusCode: 202, headers: [:], body: Data(), finalURL: endpoint)
  }

  private struct StaticHeaderProvider: MCPHTTPHeaderProvider, Sendable {
    let headers: [String: String]

    func headers(for serverID: String) async throws -> [String: String] {
      _ = serverID
      return headers
    }
  }

  private actor StubTransport: MCPHTTPTransport {
    private var queuedResponses: [MCPHTTPResponse]
    private var recordedRequests: [URLRequest] = []

    init(responses: [MCPHTTPResponse]) {
      queuedResponses = responses
    }

    func send(
      _ request: URLRequest,
      maximumResponseBytes: Int
    ) async throws -> MCPHTTPResponse {
      recordedRequests.append(request)
      guard !queuedResponses.isEmpty else {
        throw MCPClientSessionError.connectionClosed
      }
      let response = queuedResponses.removeFirst()
      guard response.body.count <= maximumResponseBytes else {
        throw MCPClientSessionError.limitExceeded
      }
      return response
    }

    func requests() -> [URLRequest] {
      recordedRequests
    }
  }
}
