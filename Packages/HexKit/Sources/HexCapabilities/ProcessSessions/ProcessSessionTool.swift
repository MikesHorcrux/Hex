import CryptoKit
import Foundation
import HexCore

public struct ProcessSessionTool: HostTool {
  public let definition: ToolDefinition
  private let manager: ProcessSessionManager
  private let action: String
  private let calls = ToolAuthorizationLedger(maximumEntries: 64)
  private let key = SymmetricKey(size: .bits256)

  public init(manager: ProcessSessionManager, action: String) throws {
    guard ["read", "list", "input", "control"].contains(action) else {
      throw ProcessSessionError.invalidRequest
    }
    self.manager = manager
    self.action = action
    let session = HostToolSchema.string("Session ID from process_start/list.", maximumLength: 36)
    let sequence = HostToolSchema.integer(
      "Current inputSequence from the session record, shared with human controls.", minimum: 0,
      maximum: Int.max - 1)
    let properties: [String: JSONValue]
    let required: [String]
    let description: String
    switch action {
    case "list":
      properties = ["before": session]
      required = []
      description =
        "List up to 50 sessions in this conversation. Pass the last ID as before for older records."
    case "read":
      properties = [
        "session_id": session,
        "offset": HostToolSchema.integer(
          "Independent byte cursor. Start at zero.", minimum: 0, maximum: 67_108_864),
        "maximum_bytes": HostToolSchema.integer(
          "Bounded output page; default 16384.", minimum: 1, maximum: 65_536),
      ]
      required = ["session_id"]
      description =
        "Read durable combined output and process state. nextOffset can be reused by this reader; no shared cursor is advanced. Check phase, exitCode and cleanupConfirmed before treating a command as done."
    case "input":
      properties = [
        "session_id": session, "expected_sequence": sequence,
        "text": HostToolSchema.string(
          "Exact UTF-8 input, including any newline. Avoid secrets; authorization shows this text.",
          maximumLength: 16_384),
      ]
      required = ["session_id", "expected_sequence", "text"]
      description =
        "Send input once. The host assigns an operation ID. acceptedBytes means transport acceptance, never proof of command success. Pending or unknown input must be reconciled; never resend it."
    default:
      properties = [
        "session_id": session, "expected_sequence": sequence,
        "action": HostToolSchema.stringEnum(
          "Session control.", values: ["interrupt", "eof", "resize", "stop"]),
        "columns": HostToolSchema.integer("PTY columns.", minimum: 1, maximum: 1_000),
        "rows": HostToolSchema.integer("PTY rows.", minimum: 1, maximum: 1_000),
      ]
      required = ["session_id", "expected_sequence", "action"]
      description =
        "Interrupt, send EOF, resize a PTY, or stop a process group. Read the session afterward to confirm exit and cleanup."
    }
    definition = ToolDefinition(
      name: "process_" + action, description: description,
      inputSchema: HostToolSchema.object(properties: properties, required: required))
  }

  private func args(_ call: ToolCall) throws -> ToolCallArguments {
    guard call.name == definition.name else { throw ProcessSessionError.invalidRequest }
    let allowed: Set<String>
    switch action {
    case "list": allowed = ["before"]
    case "read": allowed = ["session_id", "offset", "maximum_bytes"]
    case "input": allowed = ["session_id", "expected_sequence", "text"]
    default: allowed = ["session_id", "expected_sequence", "action", "columns", "rows"]
    }
    return try ToolCallArguments(call.arguments, allowedNames: allowed)
  }

  private func sessionID(_ args: ToolCallArguments) throws -> UUID {
    guard let id = UUID(uuidString: try args.requiredString(named: "session_id", maximumBytes: 36))
    else {
      throw ProcessSessionError.invalidRequest
    }
    return id
  }

  public func authorizationRequest(for call: ToolCall, in context: ToolExecutionContext)
    async throws -> AuthorizationRequest
  {
    let args = try args(call)
    let scope = try await manager.scope(context)
    if action != "list" { _ = try await manager.scoped(sessionID(args), scope.conversationID) }
    try await calls.record(call: call, runID: context.runID)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let digest = HMAC<SHA256>.authenticationCode(
      for: try encoder.encode(call.arguments), using: key
    ).map { String(format: "%02x", $0) }.joined()
    return AuthorizationRequest(
      runID: context.runID, toolCallID: call.id,
      capability: CapabilityID(
        rawValue: ["list", "read"].contains(action) ? "process.session.read" : "process.execute"),
      operation: action, resource: "process-session:\(scope.conversationID):\(digest)",
      details: call.arguments,
      explanation: ["list", "read"].contains(action)
        ? "Read this conversation's process sessions."
        : "Allow this exact input or control on the selected session.")
  }

  public func execute(_ call: ToolCall, in context: ToolExecutionContext) async throws -> ToolResult
  {
    try await calls.take(call: call, runID: context.runID)
    let args = try args(call)
    let scope = try await manager.scope(context)
    if action == "list" {
      let before = try args.optionalString(named: "before", maximumBytes: 36)
      if let before, UUID(uuidString: before) == nil { throw ProcessSessionError.invalidRequest }
      return try Self.result(
        await manager.list(
          conversationID: scope.conversationID, before: before.flatMap(UUID.init(uuidString:))),
        call: call)
    }
    let id = try sessionID(args)
    if action == "read" {
      let page = try await manager.read(
        id, conversationID: scope.conversationID,
        offset: Int64(args.optionalInteger(named: "offset", range: 0...67_108_864) ?? 0),
        maximumBytes: args.optionalInteger(named: "maximum_bytes", range: 1...65_536) ?? 16_384)
      var output = try Self.value(page)
      if case .object(var object) = output {
        if let text = ProcessPromptText.sanitizedUTF8Output(page.data) {
          object["data"] = nil
          object["text"] = .string(text.text)
          object["encoding"] = .string(text.sanitized ? "utf8_sanitized" : "utf8")
        } else {
          object["encoding"] = .string("base64")
        }
        output = .object(object)
      }
      return ToolResult(
        toolCallID: call.id, status: .success, output: output,
        requiresUserAttention: page.session.terminal && !page.session.cleanupConfirmed)
    }
    let commandAction: ProcessSessionCommand.Action
    if action == "input" {
      commandAction = .input
    } else {
      guard
        let parsed = ProcessSessionCommand.Action(
          rawValue: try args.requiredString(named: "action", maximumBytes: 16)), parsed != .input
      else {
        throw ProcessSessionError.invalidRequest
      }
      commandAction = parsed
    }
    let command = ProcessSessionCommand(
      sessionID: id,
      operationID: "\(context.runID.rawValue.uuidString):\(call.id.rawValue)",
      expectedSequence: Int64(
        try args.requiredInteger(named: "expected_sequence", range: 0...(Int.max - 1))),
      action: commandAction,
      data: commandAction == .input
        ? Data(try args.requiredString(named: "text", maximumBytes: 16_384, allowsEmpty: true).utf8)
        : Data(),
      columns: UInt16(try args.optionalInteger(named: "columns", range: 1...1_000) ?? 120),
      rows: UInt16(try args.optionalInteger(named: "rows", range: 1...1_000) ?? 30),
      originTaskID: scope.taskID)
    let receipt = try await manager.command(command, conversationID: scope.conversationID)
    return ToolResult(
      toolCallID: call.id, status: .success, output: try Self.value(receipt),
      requiresUserAttention: !["accepted", "not_sent"].contains(receipt.state))
  }

  static func value<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }

  static func result<T: Encodable>(_ value: T, call: ToolCall) throws -> ToolResult {
    ToolResult(toolCallID: call.id, status: .success, output: try Self.value(value))
  }
}
