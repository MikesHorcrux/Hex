import Foundation
import HexCore

public struct ArtifactSearchTool: HostTool, Sendable {
  public let definition = ToolDefinition(
    name: "artifact_search",
    description:
      "Search one bounded window of preserved output for exact UTF-8 literal bytes, not regex. Returns byte offsets, bounded snippets, and the next scan offset. Follow next_scan_offset to continue; partial scans never prove absence elsewhere. Binary or split-UTF8 snippets use base64.",
    inputSchema: HostToolSchema.object(
      properties: [
        "artifact_id": HostToolSchema.string(
          "An artifact UUID from this conversation.", maximumLength: 36),
        "query": HostToolSchema.string(
          "Exact nonempty UTF-8 literal, at most 1024 bytes.", maximumLength: 1_024),
        "offset": HostToolSchema.integer(
          "Starting scan byte offset, default 0.", minimum: 0, maximum: Int.max),
        "maximum_scan_bytes": HostToolSchema.integer(
          "Maximum bytes read for this scan, default 65536; must exceed query byte count.",
          minimum: 2, maximum: 262_144),
        "maximum_matches": HostToolSchema.integer(
          "Maximum matches, default 20.", minimum: 1, maximum: 100),
      ], required: ["artifact_id", "query"]))

  private let reader: any ArtifactReading

  public init(reader: any ArtifactReading) { self.reader = reader }

  public func authorizationRequest(for call: ToolCall, in context: ToolExecutionContext)
    async throws
    -> AuthorizationRequest
  {
    let parameters = try parameters(call, in: context)
    return ArtifactToolAccess.authorization(
      call: call, context: context, reference: parameters.reference,
      operation: "search", offset: parameters.offset, maximumBytes: parameters.maximumBytes)
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
      return try search(
        chunk, query: parameters.query, maximumMatches: parameters.maximumMatches, callID: call.id)
    } catch {
      return try ArtifactToolOutput.failure(error, callID: call.id)
    }
  }

  private func parameters(_ call: ToolCall, in context: ToolExecutionContext) throws
    -> (
      reference: ArtifactReference, query: Data, offset: Int64, maximumBytes: Int,
      maximumMatches: Int
    )
  {
    let arguments = try ToolCallArguments(
      call.arguments,
      allowedNames: ["artifact_id", "query", "offset", "maximum_scan_bytes", "maximum_matches"])
    let reference = try ArtifactToolAccess.reference(arguments: arguments, context: context)
    let query = Data(try arguments.requiredString(named: "query", maximumBytes: 1_024).utf8)
    let offset = try ArtifactToolAccess.offset(arguments: arguments, reference: reference)
    let maximumBytes =
      try arguments.optionalInteger(named: "maximum_scan_bytes", range: 2...262_144) ?? 65_536
    let maximumMatches =
      try arguments.optionalInteger(named: "maximum_matches", range: 1...100) ?? 20
    guard maximumBytes > query.count else { throw ToolCallArgumentsError.invalidArguments }
    return (reference, query, offset, maximumBytes, maximumMatches)
  }

  private func search(_ chunk: ArtifactChunk, query: Data, maximumMatches: Int, callID: ToolCallID)
    throws -> ToolResult
  {
    let bytes = Data(chunk.data)
    // A very short nonfinal reader response cannot safely supply enough overlap to inspect the
    // literal across its boundary. Report that limitation rather than skipping possible matches.
    guard chunk.nextOffset == nil || bytes.count >= query.count else {
      throw ArtifactToolError.insufficientSearchWindow
    }
    var matches: [JSONValue] = []
    var searchStart = bytes.startIndex
    var nextOffset: Int64?
    while searchStart < bytes.endIndex,
      let range = bytes.range(of: query, in: searchStart..<bytes.endIndex)
    {
      try Task.checkCancellation()
      let snippetStart = max(bytes.startIndex, range.lowerBound - 64)
      let snippetEnd = min(bytes.endIndex, range.upperBound + 64)
      var match = ArtifactToolOutput.encoded(bytes.subdata(in: snippetStart..<snippetEnd))
      match["offset"] = .integer(chunk.offset + Int64(range.lowerBound - bytes.startIndex))
      match["length_bytes"] = .integer(Int64(query.count))
      match["snippet_offset"] = .integer(chunk.offset + Int64(snippetStart - bytes.startIndex))
      matches.append(.object(match))
      searchStart = range.lowerBound + 1
      if matches.count == maximumMatches {
        nextOffset = chunk.offset + Int64(searchStart - bytes.startIndex)
        break
      }
    }
    let hitMatchLimit = matches.count == maximumMatches
    if !hitMatchLimit, let end = chunk.nextOffset {
      // Re-read the possible partial literal at the boundary, without repeating complete matches.
      let overlap = min(query.count - 1, max(0, bytes.count - 1))
      nextOffset = end - Int64(overlap)
    }
    let reachedEOF = nextOffset == nil
    var output = ArtifactToolOutput.metadata(chunk.reference)
    output["matches"] = .array(matches)
    output["scan_offset"] = .integer(chunk.offset)
    output["scanned_bytes"] = .integer(Int64(bytes.count))
    output["next_scan_offset"] = nextOffset.map(JSONValue.integer) ?? .null
    output["reached_eof"] = .boolean(reachedEOF)
    output["search_complete"] = .boolean(
      chunk.offset == 0 && reachedEOF && chunk.reference.isComplete)
    output["match_limit_reached"] = .boolean(hitMatchLimit)
    output["search_mode"] = .string("utf8_literal_bytes")
    output["window_is_binary_or_partial_utf8"] = .boolean(
      bytes.contains(0) || String(data: bytes, encoding: .utf8) == nil)
    return ToolResult(toolCallID: callID, status: .success, output: .object(output))
  }
}
