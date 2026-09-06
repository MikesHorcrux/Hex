import Foundation

public protocol ArtifactWriteSession: Sendable {
  /// Quota rejection accepts none of this chunk. A caller may finish the retained prefix as partial.
  func append(_ data: Data) async throws
  /// Completion is a commit receipt. Cancellation must not erase a successfully committed artifact.
  func finish(isComplete: Bool) async throws -> ArtifactReference
  /// Releases the write session without publishing a reference. It never removes committed output.
  func abandon() async
}
