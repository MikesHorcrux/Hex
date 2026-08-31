import Darwin
import Foundation
import HexProviders

actor MLXModelArtifactSnapshot {
  nonisolated let directory: URL
  private nonisolated let directoryDescriptor: Int32
  private nonisolated let directoryIdentity: MLXModelArtifactSnapshotIdentity
  private nonisolated let entries: [MLXModelArtifactSnapshotEntry]
  private nonisolated let claim: MLXModelArtifactSnapshotClaim

  init(
    directory: URL,
    directoryDescriptor: Int32,
    directoryIdentity: MLXModelArtifactSnapshotIdentity,
    entries: [MLXModelArtifactSnapshotEntry],
    claim: MLXModelArtifactSnapshotClaim
  ) {
    self.directory = directory
    self.directoryDescriptor = directoryDescriptor
    self.directoryIdentity = directoryIdentity
    self.entries = entries
    self.claim = claim
  }

  nonisolated func validateBoundPath() throws {
    try validateClaimBinding()
    var retainedDirectoryStatus = stat()
    guard
      fstat(directoryDescriptor, &retainedDirectoryStatus) == 0,
      directoryIdentity.matches(retainedDirectoryStatus)
    else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }

    let pathDescriptor = directory.path.withCString {
      open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard pathDescriptor >= 0 else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    defer { close(pathDescriptor) }

    var pathDirectoryStatus = stat()
    guard
      fstat(pathDescriptor, &pathDirectoryStatus) == 0,
      directoryIdentity.matches(pathDirectoryStatus),
      try artifactNames(
        in: pathDescriptor,
        maximumCount: entries.count
      ) == entries.map(\.name).sorted()
    else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }

    for entry in entries {
      var retainedStatus = stat()
      guard
        fstat(entry.fileDescriptor, &retainedStatus) == 0,
        entry.identity.matches(retainedStatus)
      else {
        throw MLXLocalInferenceProviderError.invalidModelConfiguration
      }
      let pathFileDescriptor = entry.name.withCString {
        openat(pathDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      }
      guard pathFileDescriptor >= 0 else {
        throw MLXLocalInferenceProviderError.invalidModelConfiguration
      }
      var pathStatus = stat()
      let matchesPath =
        fstat(pathFileDescriptor, &pathStatus) == 0
        && entry.identity.matches(pathStatus)
      close(pathFileDescriptor)
      guard matchesPath else {
        throw MLXLocalInferenceProviderError.invalidModelConfiguration
      }
    }
  }

  deinit {
    for entry in entries {
      _ = ftruncate(entry.fileDescriptor, 0)
      _ = fsync(entry.fileDescriptor)
      _ = fchmod(entry.fileDescriptor, 0)
      close(entry.fileDescriptor)
    }
    _ = fchmod(directoryDescriptor, 0)
    close(directoryDescriptor)
    close(claim.fileDescriptor)
  }

  private nonisolated func validateClaimBinding() throws {
    var retainedStatus = stat()
    guard
      fstat(claim.fileDescriptor, &retainedStatus) == 0,
      claim.identity.matches(retainedStatus)
    else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    let pathDescriptor = claim.url.path.withCString {
      open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard pathDescriptor >= 0 else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    defer { close(pathDescriptor) }
    var pathStatus = stat()
    guard
      fstat(pathDescriptor, &pathStatus) == 0,
      claim.identity.matches(pathStatus)
    else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
  }

  private nonisolated func artifactNames(
    in fileDescriptor: Int32,
    maximumCount: Int
  ) throws -> [String] {
    guard maximumCount >= 0 else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    let enumerationDescriptor = ".".withCString {
      openat(fileDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard enumerationDescriptor >= 0, let directory = fdopendir(enumerationDescriptor) else {
      if enumerationDescriptor >= 0 {
        close(enumerationDescriptor)
      }
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    defer { closedir(directory) }

    var names: [String] = []
    let enumerationCapacity = maximumCount == Int.max ? Int.max : maximumCount + 1
    names.reserveCapacity(min(enumerationCapacity, 64))
    errno = 0
    while let entry = readdir(directory) {
      let length = Int(entry.pointee.d_namlen)
      var storage = entry.pointee.d_name
      let bytes = withUnsafeBytes(of: &storage) { buffer in
        Array(buffer.prefix(length))
      }
      guard let name = String(bytes: bytes, encoding: .utf8) else {
        throw MLXLocalInferenceProviderError.invalidModelConfiguration
      }
      if name != "." && name != ".." {
        guard
          !name.isEmpty,
          name.utf8.count <= 255,
          !name.contains("/"),
          !name.contains("\0"),
          names.count <= maximumCount
        else {
          throw MLXLocalInferenceProviderError.invalidModelConfiguration
        }
        names.append(name)
        if names.count > maximumCount {
          throw MLXLocalInferenceProviderError.invalidModelConfiguration
        }
      }
    }
    guard errno == 0 else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    return names.sorted()
  }
}
