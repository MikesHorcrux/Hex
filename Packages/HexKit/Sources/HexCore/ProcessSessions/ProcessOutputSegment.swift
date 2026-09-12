import Foundation

public struct ProcessOutputSegment: Codable, Equatable, Sendable {
  public let sessionID: UUID
  public let offset: Int64
  public let reference: ArtifactReference
  public init(sessionID: UUID, offset: Int64, reference: ArtifactReference) {
    self.sessionID = sessionID
    self.offset = offset
    self.reference = reference
  }
}
