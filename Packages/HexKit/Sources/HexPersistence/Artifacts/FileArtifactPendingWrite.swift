import CryptoKit
import Darwin
import Foundation
import HexCore

/// Mutable state is confined to FileArtifactStore. Descriptor lifetime follows the pending write;
/// abandoning it closes the descriptor but deliberately leaves quota-accounted crash residue.
final class FileArtifactPendingWrite {
  let id: UUID
  let metadata: ArtifactMetadata
  let descriptor: Int32
  var byteCount: Int64 = 0
  var hash = SHA256()

  init(id: UUID, metadata: ArtifactMetadata, descriptor: Int32) {
    self.id = id
    self.metadata = metadata
    self.descriptor = descriptor
  }

  deinit { Darwin.close(descriptor) }

  func append(_ data: Data) throws {
    var consumed = 0
    while consumed < data.count {
      let requested = min(64 * 1_024, data.count - consumed)
      let count = data.withUnsafeBytes { bytes in
        Darwin.pwrite(
          descriptor, bytes.baseAddress?.advanced(by: consumed), requested,
          off_t(byteCount))
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw ArtifactStoreError.unavailable }
      hash.update(data: data.subdata(in: consumed..<(consumed + count)))
      consumed += count
      byteCount += Int64(count)
    }
  }
}
