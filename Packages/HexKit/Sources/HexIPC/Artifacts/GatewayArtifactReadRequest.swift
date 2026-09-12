import HexCore

/// The local app supplies a complete immutable manifest, never a filesystem path. The resident
/// reader must match that manifest against its own store before returning any bytes.
public struct GatewayArtifactReadRequest: Codable, Equatable, Sendable {
  public let reference: ArtifactReference
  public let offset: Int64
  public let maximumBytes: Int

  public init(reference: ArtifactReference, offset: Int64 = 0, maximumBytes: Int = 16_384) {
    self.reference = reference
    self.offset = offset
    self.maximumBytes = maximumBytes
  }
}
