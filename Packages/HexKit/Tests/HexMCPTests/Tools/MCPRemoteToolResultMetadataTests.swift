import Foundation
import HexCore
import Testing

@testable import HexMCP

@Suite("Bounded MCP result metadata")
struct MCPRemoteToolResultMetadataTests {
  @Test
  func preservesHelperTargetAndDispatchMetadataAlongsideTheKnownReceipt() throws {
    let metadata: JSONValue = .object([
      "target_receipt": .object([
        "pid": .integer(123), "window_id": .integer(456),
        "process_start_identity_decimal": .string("1788823729213649"),
      ]),
      "dispatch_state": .string("none"), "mutation_dispatched": .boolean(false),
    ])
    let decoded = try decode(metadata, isError: true)
    #expect(decoded.metadata == metadata)
    #expect(decoded.isError)
    let call = ToolCall(name: "mcp_8_peekaboo_click", arguments: [:])
    let result = try MCPToolResultMapper.map(decoded, call: call, route: route)
    #expect(result.toolCallID == call.id)
    #expect(result.status == .failure)
    #expect(result.content == [.text("Delivered helper receipt")])
    #expect(field(result, "_meta") == metadata)
  }

  @Test(arguments: ["string", "huge_string", "many_nodes", "escaped_bytes", "null"])
  func invalidOptionalMetadataCannotDiscardAnOtherwiseDeliveredReceipt(reason: String) throws {
    let metadata: JSONValue
    switch reason {
    case "string": metadata = .string("not an object")
    case "huge_string":
      metadata = .object(["large": .string(String(repeating: "a", count: 32 * 1_024 + 1))])
    case "many_nodes":
      metadata = .object(["nodes": .array(Array(repeating: .integer(1), count: 4_097))])
    case "escaped_bytes":
      metadata = .object(["large": .string(String(repeating: "\u{1}", count: 20_000))])
    default: metadata = .null
    }
    let decoded = try decode(metadata, isError: true)
    #expect(decoded.metadata == nil)
    #expect(decoded.content == [.text("Delivered helper receipt")])
    #expect(decoded.isError)
    // Also defend the public value initializer used by non-JSON transports.
    let remote = MCPRemoteToolResult(
      content: [.text("Delivered helper receipt")], metadata: metadata, isError: true)
    let mapped = try MCPToolResultMapper.map(
      remote,
      call: ToolCall(name: "mcp_8_peekaboo_click", arguments: [:]), route: route)
    #expect(mapped.status == .failure)
    #expect(mapped.content == [.text("Delivered helper receipt")])
    #expect(field(mapped, "_meta") == nil)
  }

  @Test
  func optionalMetadataCannotPushAValidContentReceiptBeyondTheAggregateBudget() throws {
    let first = String(repeating: "a", count: 1_024 * 1_024 - 400)
    let second = String(repeating: "b", count: 1_024 * 1_024 - 400)
    let metadata: JSONValue = .object(["diagnostic": .string(String(repeating: "m", count: 8_192))])
    let remote = MCPRemoteToolResult(
      content: [.text(first), .text(second)], metadata: metadata, isError: false)
    let mapped = try MCPToolResultMapper.map(
      remote,
      call: ToolCall(name: "mcp_8_peekaboo_see", arguments: [:]), route: route)
    #expect(mapped.status == .success)
    #expect(mapped.content == [.text(first), .text(second)])
    #expect(field(mapped, "_meta") == nil)
    #expect(try JSONEncoder().encode(mapped.output).count <= 2 * 1_024 * 1_024)
  }

  @Test
  func metadataRemainsOptionalForExistingServers() throws {
    let result = try MCPRemoteToolResultDecoder.decode(
      .object([
        "content": .array([.object(["type": .string("text"), "text": .string("ordinary")])])
      ]), maximumContentItems: 8)
    #expect(result.metadata == nil)
    #expect(!result.isError)
    #expect(result.content == [.text("ordinary")])
  }

  private func decode(_ metadata: JSONValue, isError: Bool = false) throws -> MCPRemoteToolResult {
    try MCPRemoteToolResultDecoder.decode(
      .object([
        "content": .array([
          .object(["type": .string("text"), "text": .string("Delivered helper receipt")])
        ]),
        "_meta": metadata, "isError": .boolean(isError),
      ]), maximumContentItems: 8)
  }

  private var route: MCPToolRoute {
    MCPToolRoute(session: Session(), serverID: "peekaboo", remoteName: "click")
  }
  private func field(_ result: ToolResult, _ key: String) -> JSONValue? {
    guard case .object(let fields) = result.output else { return nil }
    return fields[key]
  }
  private struct Session: MCPClientSession {
    let serverID = "peekaboo"
    func connect() async throws {}
    func disconnect() async {}
    func listTools() async throws -> [MCPRemoteTool] { [] }
    func callTool(_ call: MCPRemoteToolCall) async throws -> MCPRemoteToolResult {
      MCPRemoteToolResult(content: [], isError: false)
    }
  }
}
