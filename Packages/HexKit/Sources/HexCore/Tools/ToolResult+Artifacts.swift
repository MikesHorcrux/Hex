import Foundation

extension ToolResult {
  /// Provider-visible identifiers and read instructions, without disclosing storage paths.
  public var artifactDescriptions: JSONValue {
    .array(
      artifacts.map { artifact in
        .object([
          "artifact_id": .string(artifact.id.uuidString),
          "media_type": .string(artifact.mediaType),
          "byte_count": .integer(artifact.byteCount),
          "sha256": .string(artifact.sha256),
          "complete": .boolean(artifact.isComplete),
          "read_with": .string("artifact_read"),
          "search_with": .string("artifact_search"),
        ])
      })
  }
}
