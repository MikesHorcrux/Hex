import CryptoKit
import Darwin
import Foundation
import HexCore

enum FileArtifactIO {
  static let maximumManifestBytes = 4_096
  static let maximumReadBytes = 1_024 * 1_024

  static func status(_ descriptor: Int32, mode: mode_t? = nil) throws -> stat {
    var value = stat()
    guard fstat(descriptor, &value) == 0 else { throw ArtifactStoreError.unavailable }
    guard value.st_mode & S_IFMT == S_IFREG, value.st_uid == geteuid(), value.st_nlink == 1,
      value.st_size >= 0,
      mode.map({ value.st_mode & 0o7777 == $0 })
        ?? [mode_t(0o400), mode_t(0o600)].contains(value.st_mode & 0o7777)
    else { throw ArtifactStoreError.corrupt }
    return value
  }

  static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }

  static func unchanged(_ lhs: stat, _ rhs: stat) -> Bool {
    sameIdentity(lhs, rhs) && lhs.st_size == rhs.st_size && lhs.st_mode == rhs.st_mode
      && lhs.st_nlink == rhs.st_nlink && lhs.st_uid == rhs.st_uid
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }

  static func read(_ descriptor: Int32, offset: Int64, count: Int) throws -> Data {
    var data = Data(count: count)
    var received = 0
    while received < count {
      let result = data.withUnsafeMutableBytes { bytes in
        Darwin.pread(
          descriptor, bytes.baseAddress?.advanced(by: received), count - received,
          off_t(offset + Int64(received)))
      }
      if result < 0, errno == EINTR { continue }
      guard result > 0 else { throw ArtifactStoreError.corrupt }
      received += result
    }
    return data
  }

  static func checksum(_ descriptor: Int32, byteCount: Int64) throws -> String {
    var hash = SHA256()
    var offset: Int64 = 0
    while offset < byteCount {
      let count = Int(min(64 * 1_024, byteCount - offset))
      hash.update(data: try read(descriptor, offset: offset, count: count))
      offset += Int64(count)
    }
    return hex(hash.finalize())
  }

  static func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  static func write(_ data: Data, to descriptor: Int32) throws {
    var written = 0
    while written < data.count {
      let count = data.withUnsafeBytes { bytes in
        Darwin.pwrite(
          descriptor, bytes.baseAddress?.advanced(by: written), data.count - written,
          off_t(written))
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw ArtifactStoreError.unavailable }
      written += count
    }
  }

  static func canonicalData(_ reference: ArtifactReference) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(reference), data.count <= maximumManifestBytes else {
      throw ArtifactStoreError.invalidRequest
    }
    return data
  }

  static func validate(_ metadata: ArtifactMetadata) throws {
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    guard metadata.runID.rawValue != zero,
      metadata.toolCallID.map({
        !$0.rawValue.isEmpty && $0.rawValue.utf8.count <= 512
          && $0.rawValue.utf8.allSatisfy { (0x21...0x7e).contains($0) }
      }) ?? true,
      !metadata.mediaType.isEmpty, metadata.mediaType.utf8.count <= 128,
      metadata.mediaType.contains("/"),
      metadata.mediaType.utf8.allSatisfy({ (0x21...0x7e).contains($0) })
    else { throw ArtifactStoreError.invalidRequest }
  }

  static func validate(_ reference: ArtifactReference) throws {
    try validate(
      ArtifactMetadata(
        runID: reference.runID, toolCallID: reference.toolCallID, mediaType: reference.mediaType))
    guard reference.id != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
      reference.byteCount >= 0, reference.sha256.utf8.count == 64,
      reference.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw ArtifactStoreError.invalidRequest }
  }
}
