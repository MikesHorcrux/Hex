import Foundation
import HexCore

enum ArtifactToolOutput {
  static func metadata(_ reference: ArtifactReference) -> [String: JSONValue] {
    [
      "artifact_id": .string(reference.id.uuidString),
      "source_run_id": .string(reference.runID.rawValue.uuidString),
      "media_type": .string(reference.mediaType), "sha256": .string(reference.sha256),
      "full_byte_count": .integer(reference.byteCount),
      "is_complete": .boolean(reference.isComplete),
    ]
  }

  /// A bounded slice can start or end inside a UTF-8 scalar. Preserve its exact bytes as base64 in
  /// that case; replacement characters would make byte offsets impossible to round-trip faithfully.
  static func encoded(_ data: Data) -> [String: JSONValue] {
    if let text = String(data: data, encoding: .utf8), !data.contains(0) {
      return ["encoding": .string("utf8"), "content": .string(text)]
    }
    return ["encoding": .string("base64"), "content": .string(data.base64EncodedString())]
  }

  static func failure(_ error: any Error, callID: ToolCallID) throws -> ToolResult {
    if error is CancellationError { throw error }
    let code: String
    switch error {
    case is ToolCallArgumentsError: code = "invalid_arguments"
    case ArtifactToolError.unknownArtifact: code = "artifact_not_in_conversation"
    case ArtifactToolError.invalidReference: code = "invalid_artifact_reference"
    case ArtifactToolError.inconsistentChunk: code = "inconsistent_artifact_chunk"
    case ArtifactToolError.insufficientSearchWindow: code = "artifact_search_window_too_small"
    case ArtifactStoreError.corrupt: code = "artifact_corrupt"
    case ArtifactStoreError.invalidRequest: code = "invalid_artifact_request"
    case ArtifactStoreError.quotaExceeded: code = "artifact_quota_exceeded"
    default: code = "artifact_unavailable"
    }
    return ToolResult(
      toolCallID: callID, status: .failure, output: .object(["error": .string(code)]))
  }
}
