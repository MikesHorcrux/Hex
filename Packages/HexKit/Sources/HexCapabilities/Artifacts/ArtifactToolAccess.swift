import Foundation
import HexCore

/// Models supply an ID, not a path or a replacement manifest. Only references already present in
/// the host-provided conversation context can become authorization resources or reader inputs.
enum ArtifactToolAccess {
  static func reference(
    arguments: ToolCallArguments, context: ToolExecutionContext
  ) throws -> ArtifactReference {
    let rawID = try arguments.requiredString(named: "artifact_id", maximumBytes: 36)
    guard let id = UUID(uuidString: rawID) else { throw ToolCallArgumentsError.invalidArguments }
    let matches = context.artifacts.filter { $0.id == id }
    guard let reference = matches.first else { throw ArtifactToolError.unknownArtifact }
    guard matches.allSatisfy({ $0 == reference }), reference.byteCount >= 0,
      reference.sha256.utf8.count == 64,
      reference.sha256.utf8.allSatisfy({
        (48...57).contains($0) || (97...102).contains($0)
      })
    else { throw ArtifactToolError.invalidReference }
    return reference
  }

  static func offset(arguments: ToolCallArguments, reference: ArtifactReference) throws -> Int64 {
    let offset = Int64(try arguments.optionalInteger(named: "offset", range: 0...Int.max) ?? 0)
    guard offset <= reference.byteCount else { throw ToolCallArgumentsError.invalidArguments }
    return offset
  }

  static func authorization(
    call: ToolCall, context: ToolExecutionContext, reference: ArtifactReference,
    operation: String, offset: Int64, maximumBytes: Int
  ) -> AuthorizationRequest {
    AuthorizationRequest(
      runID: context.runID, toolCallID: call.id,
      capability: CapabilityID(rawValue: "artifact.read"), operation: operation,
      resource: "artifact:\(reference.id.uuidString):sha256:\(reference.sha256)",
      details: [
        "artifact_id": .string(reference.id.uuidString),
        "sha256": .string(reference.sha256),
        "source_run_id": .string(reference.runID.rawValue.uuidString),
        "offset": .integer(offset), "maximum_bytes": .integer(Int64(maximumBytes)),
      ],
      explanation: "Allow Hex to inspect this preserved tool output from the conversation.")
  }

  static func validate(
    _ chunk: ArtifactChunk, reference: ArtifactReference, offset: Int64, maximumBytes: Int
  ) throws {
    guard chunk.reference == reference, chunk.offset == offset,
      chunk.data.count <= maximumBytes,
      Int64(chunk.data.count) <= reference.byteCount - offset,
      !chunk.data.isEmpty || offset == reference.byteCount
    else { throw ArtifactToolError.inconsistentChunk }
    let end = offset + Int64(chunk.data.count)
    guard chunk.nextOffset == (end < reference.byteCount ? end : nil) else {
      throw ArtifactToolError.inconsistentChunk
    }
  }
}
