import Darwin
import Foundation
import HexProviders

actor MLXModelArtifactSnapshot {
  nonisolated let directory: URL
  private nonisolated let directoryDescriptor: Int32
  private nonisolated let directoryIdentity: MLXModelArtifactSnapshotIdentity
  private nonisolated let entries: [MLXModelArtifactSnapshotEntry]

  init(
    directory: URL,
    directoryDescriptor: Int32,
    directoryIdentity: MLXModelArtifactSnapshotIdentity,
    entries: [MLXModelArtifactSnapshotEntry]
  ) {
    self.directory = directory
    self.directoryDescriptor = directoryDescriptor
    self.directoryIdentity = directoryIdentity
    self.entries = entries
  }

  nonisolated func validateBoundPath() throws {
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
      try artifactNames(in: pathDescriptor) == entries.map(\.name).sorted()
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
  }

  private nonisolated func artifactNames(in fileDescriptor: Int32) throws -> [String] {
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
        names.append(name)
      }
    }
    guard errno == 0 else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    return names.sorted()
  }
}
