import HexCore

public struct ArtifactReadTool: HostTool, Sendable {
  public let definition = ToolDefinition(
    name: "artifact_read",
    description:
      "Read a bounded byte range from preserved tool output referenced in this conversation, including earlier turns. Returns exact UTF-8 or base64 bytes and a continuation offset; EOF refers to saved bytes, not necessarily complete original output.",
    inputSchema: HostToolSchema.object(
      properties: [
        "artifact_id": HostToolSchema.string(
          "An artifact UUID from a prior tool result.", maximumLength: 36),
        "offset": HostToolSchema.integer(
          "Starting byte offset, default 0.", minimum: 0, maximum: Int.max),
        "maximum_bytes": HostToolSchema.integer(
          "Maximum bytes to return, default 16384.", minimum: 1, maximum: 65_536),
      ], required: ["artifact_id"]))

  private let reader: any ArtifactReading

  public init(reader: any ArtifactReading) { self.reader = reader }

  public func authorizationRequest(for call: ToolCall, in context: ToolExecutionContext)
    async throws
    -> AuthorizationRequest
  {
    let parameters = try parameters(call, in: context)
    return ArtifactToolAccess.authorization(
      call: call, context: context, reference: parameters.reference,
      operation: "read", offset: parameters.offset, maximumBytes: parameters.maximumBytes)
  }

  public func execute(_ call: ToolCall, in context: ToolExecutionContext) async throws -> ToolResult
  {
    do {
      try Task.checkCancellation()
      let parameters = try parameters(call, in: context)
      let chunk = try await reader.read(
        parameters.reference, offset: parameters.offset, maximumBytes: parameters.maximumBytes)
      try Task.checkCancellation()
      try ArtifactToolAccess.validate(
        chunk, reference: parameters.reference, offset: parameters.offset,
        maximumBytes: parameters.maximumBytes)
      var output = ArtifactToolOutput.metadata(chunk.reference)
      output.merge(ArtifactToolOutput.encoded(chunk.data)) { _, new in new }
      output["offset"] = .integer(chunk.offset)
      output["returned_bytes"] = .integer(Int64(chunk.data.count))
      output["next_offset"] = chunk.nextOffset.map(JSONValue.integer) ?? .null
      output["eof"] = .boolean(chunk.nextOffset == nil)
      return ToolResult(toolCallID: call.id, status: .success, output: .object(output))
    } catch {
      return try ArtifactToolOutput.failure(error, callID: call.id)
    }
  }

  private func parameters(_ call: ToolCall, in context: ToolExecutionContext) throws
    -> (reference: ArtifactReference, offset: Int64, maximumBytes: Int)
  {
    let arguments = try ToolCallArguments(
      call.arguments, allowedNames: ["artifact_id", "offset", "maximum_bytes"])
    let reference = try ArtifactToolAccess.reference(arguments: arguments, context: context)
    let offset = try ArtifactToolAccess.offset(arguments: arguments, reference: reference)
    let maximumBytes =
      try arguments.optionalInteger(named: "maximum_bytes", range: 1...65_536) ?? 16_384
    return (reference, offset, maximumBytes)
  }
}
