import Foundation

public protocol ArtifactWriting: Sendable {
  func begin(_ metadata: ArtifactMetadata) async throws -> any ArtifactWriteSession
}

extension ArtifactWriting {
  public func store(_ data: Data, metadata: ArtifactMetadata) async throws -> ArtifactReference {
    let session = try await begin(metadata)
    do {
      try await session.append(data)
      return try await session.finish(isComplete: true)
    } catch {
      await session.abandon()
      throw error
    }
  }
}
