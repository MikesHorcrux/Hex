import Foundation

public struct WorkspacePatchFileReceipt: Codable, Equatable, Sendable {
  public let path: String
  public let before: ArtifactReference?
  public let after: ArtifactReference?
  public let expectedRevision: String?
  public var resultingRevision: String?
  public var state = "pending"
  public var tombstone: String?
  public init(
    path: String, before: ArtifactReference?, after: ArtifactReference?, expectedRevision: String?
  ) {
    self.path = path
    self.before = before
    self.after = after
    self.expectedRevision = expectedRevision
  }
}
