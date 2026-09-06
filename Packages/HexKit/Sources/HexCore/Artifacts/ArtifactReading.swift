public protocol ArtifactReading: Sendable {
  /// Reads a bounded byte range, verifying the stored manifest exactly matches the supplied reference.
  func read(_ reference: ArtifactReference, offset: Int64, maximumBytes: Int) async throws
    -> ArtifactChunk
}
