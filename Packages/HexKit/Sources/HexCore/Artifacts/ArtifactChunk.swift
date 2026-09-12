import Foundation

public struct ArtifactChunk: Equatable, Sendable {
  public let reference: ArtifactReference
  public let offset: Int64
  public let data: Data
  public let nextOffset: Int64?

  public init(reference: ArtifactReference, offset: Int64, data: Data, nextOffset: Int64?) {
    self.reference = reference
    self.offset = offset
    self.data = data
    self.nextOffset = nextOffset
  }
}
