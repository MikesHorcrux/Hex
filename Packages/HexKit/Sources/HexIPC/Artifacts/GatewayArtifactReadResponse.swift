import Foundation
import HexCore

public struct GatewayArtifactReadResponse: Codable, Equatable, Sendable {
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

  public init(chunk: ArtifactChunk) {
    self.init(
      reference: chunk.reference, offset: chunk.offset, data: chunk.data,
      nextOffset: chunk.nextOffset)
  }
}
