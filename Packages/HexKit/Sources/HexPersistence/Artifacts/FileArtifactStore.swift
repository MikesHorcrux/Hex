import CryptoKit
import Darwin
import Foundation
import HexCore

/// Immutable output storage with bounded memory and explicit quota failure. The quota accounts for
/// blob bytes, including abandoned/crash leftovers; no garbage collection or silent eviction occurs.
/// A commit syncs blob contents and directory before publishing a separately synced manifest. This
/// uses fsync, not a guarantee against every storage-device or power-loss failure.
public actor FileArtifactStore: ArtifactWriting, ArtifactReading {
  private let directory: FileArtifactDirectory
  private let maximumArtifactBytes: Int64
  private let maximumTotalBytes: Int64
  private var pending: [UUID: FileArtifactPendingWrite] = [:]
  private var verified: [UUID: (reference: ArtifactReference, status: stat)] = [:]

  public init(
    rootURL: URL, maximumArtifactBytes: Int64 = 64 * 1_024 * 1_024,
    maximumTotalBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
  ) throws {
    guard maximumArtifactBytes > 0, maximumTotalBytes >= maximumArtifactBytes else {
      throw ArtifactStoreError.invalidRequest
    }
    let directory = try FileArtifactDirectory(url: rootURL)
    try directory.withLock {
      guard try FileArtifactInventory.payloadBytes(in: directory) <= maximumTotalBytes else {
        throw ArtifactStoreError.quotaExceeded
      }
    }
    self.directory = directory
    self.maximumArtifactBytes = maximumArtifactBytes
    self.maximumTotalBytes = maximumTotalBytes
  }

  public func begin(_ metadata: ArtifactMetadata) throws -> any ArtifactWriteSession {
    try Task.checkCancellation()
    try FileArtifactIO.validate(metadata)
    let id = UUID()
    try directory.withLock {
      guard
        try FileArtifactInventory.payloadBytes(in: directory, reservingArtifacts: 1)
          <= maximumTotalBytes
      else {
        throw ArtifactStoreError.quotaExceeded
      }
      let descriptor = Darwin.openat(
        directory.descriptor, blobName(id), O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        mode_t(0o600))
      guard descriptor >= 0 else { throw ArtifactStoreError.unavailable }
      do { _ = try FileArtifactIO.status(descriptor, mode: 0o600) } catch {
        Darwin.close(descriptor)
        throw error
      }
      pending[id] = FileArtifactPendingWrite(id: id, metadata: metadata, descriptor: descriptor)
    }
    return FileArtifactWriteSession(store: self, id: id)
  }

  func append(_ data: Data, to id: UUID) throws {
    try Task.checkCancellation()
    guard let write = pending[id] else { throw ArtifactStoreError.invalidRequest }
    try directory.withLock {
      let status = try validatePending(write, writable: true)
      let (next, overflow) = write.byteCount.addingReportingOverflow(Int64(data.count))
      guard !overflow, next <= maximumArtifactBytes else { throw ArtifactStoreError.quotaExceeded }
      let usage = try FileArtifactInventory.payloadBytes(in: directory)
      guard Int64(data.count) <= maximumTotalBytes - usage else {
        throw ArtifactStoreError.quotaExceeded
      }
      // The entire quota check precedes the first byte. I/O failures may preserve a shorter prefix;
      // its byte count/hash advance only for writes the kernel actually accepted.
      guard status.st_size == write.byteCount else { throw ArtifactStoreError.corrupt }
      try write.append(data)
    }
  }

  func finish(_ id: UUID, isComplete: Bool) throws -> ArtifactReference {
    // Intentionally no cancellation check: the caller may already have a known external outcome.
    guard let write = pending[id] else { throw ArtifactStoreError.invalidRequest }
    return try directory.withLock {
      _ = try validatePending(write, writable: false)
      guard fchmod(write.descriptor, mode_t(0o400)) == 0 else {
        throw ArtifactStoreError.unavailable
      }
      let before = try FileArtifactIO.status(write.descriptor, mode: 0o400)
      let digest = FileArtifactIO.hex(write.hash.finalize())
      guard try FileArtifactIO.checksum(write.descriptor, byteCount: write.byteCount) == digest,
        FileArtifactIO.unchanged(before, try FileArtifactIO.status(write.descriptor))
      else { throw ArtifactStoreError.corrupt }
      let reference = ArtifactReference(
        id: id, runID: write.metadata.runID, toolCallID: write.metadata.toolCallID,
        mediaType: write.metadata.mediaType, byteCount: write.byteCount, sha256: digest,
        isComplete: isComplete)
      guard Darwin.fsync(write.descriptor) == 0
      else { throw ArtifactStoreError.unavailable }
      try directory.synchronize()
      try publishManifest(reference)
      try validateNamedBlob(id, status: before)
      pending.removeValue(forKey: id)
      return reference
    }
  }

  func abandon(_ id: UUID) {
    // No pathname deletion: a renamed/replaced entry must never make cleanup target unrelated data.
    // Retained partial files are accounted for by the same quota after restart.
    pending.removeValue(forKey: id)
  }

  public func read(_ reference: ArtifactReference, offset: Int64, maximumBytes: Int) throws
    -> ArtifactChunk
  {
    try Task.checkCancellation()
    try FileArtifactIO.validate(reference)
    guard offset >= 0, offset <= reference.byteCount,
      reference.byteCount <= maximumArtifactBytes,
      (1...FileArtifactIO.maximumReadBytes).contains(maximumBytes)
    else { throw ArtifactStoreError.invalidRequest }
    return try directory.withLock {
      try validateManifest(reference)
      let descriptor = try openBlob(reference.id)
      defer { Darwin.close(descriptor) }
      let before = try FileArtifactIO.status(descriptor, mode: 0o400)
      guard before.st_size == reference.byteCount else { throw ArtifactStoreError.corrupt }
      if let cached = verified[reference.id], cached.reference == reference,
        FileArtifactIO.unchanged(cached.status, before)
      {
        // The immutable inode has already been checksummed. Any size/mode/mtime/ctime change forces
        // a fresh streaming verification; a range read never allocates the whole artifact.
      } else {
        guard
          try FileArtifactIO.checksum(descriptor, byteCount: reference.byteCount)
            == reference.sha256
        else { throw ArtifactStoreError.corrupt }
      }
      let count = Int(min(Int64(maximumBytes), reference.byteCount - offset))
      let data = try FileArtifactIO.read(descriptor, offset: offset, count: count)
      let after = try FileArtifactIO.status(descriptor, mode: 0o400)
      guard FileArtifactIO.unchanged(before, after) else { throw ArtifactStoreError.corrupt }
      try validateNamedBlob(reference.id, status: after)
      if verified.count >= 128 { verified.removeAll(keepingCapacity: true) }
      verified[reference.id] = (reference, after)
      let next = offset + Int64(data.count)
      return ArtifactChunk(
        reference: reference, offset: offset, data: data,
        nextOffset: next < reference.byteCount ? next : nil)
    }
  }

  private func validatePending(_ write: FileArtifactPendingWrite, writable: Bool) throws -> stat {
    let status = try FileArtifactIO.status(write.descriptor, mode: writable ? 0o600 : nil)
    guard status.st_size == write.byteCount else { throw ArtifactStoreError.corrupt }
    try validateNamedBlob(write.id, status: status)
    return status
  }

  private func validateNamedBlob(_ id: UUID, status: stat) throws {
    var named = stat()
    guard fstatat(directory.descriptor, blobName(id), &named, AT_SYMLINK_NOFOLLOW) == 0,
      FileArtifactIO.unchanged(status, named)
    else { throw ArtifactStoreError.corrupt }
  }

  private func openBlob(_ id: UUID) throws -> Int32 {
    let descriptor = Darwin.openat(
      directory.descriptor, blobName(id), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw ArtifactStoreError.unavailable }
    return descriptor
  }

  private func publishManifest(_ reference: ArtifactReference) throws {
    let data = try FileArtifactIO.canonicalData(reference)
    let name = manifestName(reference.id)
    let descriptor = Darwin.openat(
      directory.descriptor, name, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      mode_t(0o600))
    if descriptor < 0 {
      guard errno == EEXIST else { throw ArtifactStoreError.unavailable }
      // Retry only an exact, fully written manifest left by an earlier uncertain fsync result.
      try validateManifest(reference, finalModeRequired: false)
      let existing = Darwin.openat(
        directory.descriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
      guard existing >= 0 else { throw ArtifactStoreError.unavailable }
      defer { Darwin.close(existing) }
      _ = try FileArtifactIO.status(existing)
      guard fchmod(existing, mode_t(0o400)) == 0, Darwin.fsync(existing) == 0 else {
        throw ArtifactStoreError.unavailable
      }
      try directory.synchronize()
      try validateManifest(reference)
      return
    }
    defer { Darwin.close(descriptor) }
    _ = try FileArtifactIO.status(descriptor, mode: 0o600)
    try FileArtifactIO.write(data, to: descriptor)
    guard fchmod(descriptor, mode_t(0o400)) == 0, Darwin.fsync(descriptor) == 0 else {
      throw ArtifactStoreError.unavailable
    }
    try directory.synchronize()
    try validateManifest(reference)
  }

  private func validateManifest(_ reference: ArtifactReference, finalModeRequired: Bool = true)
    throws
  {
    let name = manifestName(reference.id)
    let descriptor = Darwin.openat(
      directory.descriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw ArtifactStoreError.unavailable }
    defer { Darwin.close(descriptor) }
    let before = try FileArtifactIO.status(descriptor, mode: finalModeRequired ? 0o400 : nil)
    guard before.st_size > 0, before.st_size <= FileArtifactIO.maximumManifestBytes else {
      throw ArtifactStoreError.corrupt
    }
    let data = try FileArtifactIO.read(descriptor, offset: 0, count: Int(before.st_size))
    guard let decoded = try? JSONDecoder().decode(ArtifactReference.self, from: data),
      decoded == reference, try FileArtifactIO.canonicalData(decoded) == data,
      FileArtifactIO.unchanged(before, try FileArtifactIO.status(descriptor))
    else { throw ArtifactStoreError.corrupt }
    var named = stat()
    guard fstatat(directory.descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
      FileArtifactIO.unchanged(before, named)
    else { throw ArtifactStoreError.corrupt }
  }

  private func blobName(_ id: UUID) -> String { id.uuidString.lowercased() + ".blob" }
  private func manifestName(_ id: UUID) -> String { id.uuidString.lowercased() + ".json" }
}
