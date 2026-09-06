import HexCore

/// Lists only host-provided conversation references; no filesystem enumeration or path grants.
public struct ArtifactListTool: HostTool, Sendable {
  public let definition = ToolDefinition(
    name: "artifact_list",
    description:
      "List preserved output from this conversation, including output from before a conversation summary. Returns a bounded page of IDs, sizes and source tool calls; use artifact_read or artifact_search for contents.",
    inputSchema: HostToolSchema.object(
      properties: [
        "offset": HostToolSchema.integer("Catalog offset, default 0.", minimum: 0, maximum: 256),
        "limit": HostToolSchema.integer("Maximum entries, default 10.", minimum: 1, maximum: 20),
      ], required: []))

  public init() {}

  public func authorizationRequest(for call: ToolCall, in context: ToolExecutionContext)
    async throws -> AuthorizationRequest
  {
    _ = try parameters(call, in: context)
    return AuthorizationRequest(
      runID: context.runID, toolCallID: call.id,
      capability: CapabilityID(rawValue: "artifact.read"), operation: "list",
      resource: "conversation-output-catalog:\(context.runID.rawValue.uuidString)",
      explanation: "Allow Hex to list metadata for output already preserved in this conversation.")
  }

  public func execute(_ call: ToolCall, in context: ToolExecutionContext) async throws -> ToolResult
  {
    do {
      try Task.checkCancellation()
      let (offset, limit) = try parameters(call, in: context)
      let end = min(context.artifacts.count, offset + limit)
      let entries = context.artifacts[offset..<end].map { reference -> JSONValue in
        var fields = ArtifactToolOutput.metadata(reference)
        fields["source_tool_call_id"] = reference.toolCallID.map { .string($0.rawValue) } ?? .null
        return .object(fields)
      }
      return ToolResult(
        toolCallID: call.id, status: .success,
        output: .object([
          "artifacts": .array(entries), "total": .integer(Int64(context.artifacts.count)),
          "offset": .integer(Int64(offset)),
          "next_offset": end < context.artifacts.count ? .integer(Int64(end)) : .null,
        ]))
    } catch { return try ArtifactToolOutput.failure(error, callID: call.id) }
  }

  private func parameters(_ call: ToolCall, in context: ToolExecutionContext) throws -> (Int, Int) {
    guard call.name == definition.name else { throw ToolCallArgumentsError.invalidArguments }
    try ToolArtifactValidation.validate(context.artifacts)
    let arguments = try ToolCallArguments(call.arguments, allowedNames: ["offset", "limit"])
    let offset =
      try arguments.optionalInteger(named: "offset", range: 0...context.artifacts.count) ?? 0
    let limit = try arguments.optionalInteger(named: "limit", range: 1...20) ?? 10
    return (offset, limit)
  }
}
