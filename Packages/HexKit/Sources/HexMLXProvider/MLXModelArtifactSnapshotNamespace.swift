import Darwin
import Foundation
import HexProviders

struct MLXModelArtifactSnapshotNamespace: Sendable {
  static let maximumSnapshotCount = 16

  let directory: URL
  let snapshotLimit: Int

  init() {
    directory = FileManager.default.temporaryDirectory.appending(
      path: "hex-mlx-snapshots-\(getpid())",
      directoryHint: .isDirectory
    )
    snapshotLimit = Self.maximumSnapshotCount
  }

  init(directory: URL, snapshotLimit: Int) throws {
    guard
      directory.isFileURL,
      directory.path.hasPrefix("/"),
      !directory.path.contains("\0"),
      (1...Self.maximumSnapshotCount).contains(snapshotLimit)
    else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    self.directory = directory.standardizedFileURL
    self.snapshotLimit = snapshotLimit
  }

  func makeSnapshotDirectory() throws -> (directory: URL, fileDescriptor: Int32) {
    let createResult = directory.path.withCString {
      mkdir($0, S_IRWXU)
    }
    guard createResult == 0 || errno == EEXIST else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    let namespaceDescriptor = directory.path.withCString {
      open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard namespaceDescriptor >= 0 else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    defer { close(namespaceDescriptor) }
    try validateNamespace(namespaceDescriptor)

    for index in 0..<snapshotLimit {
      let name = "snapshot-\(index)"
      let result = name.withCString {
        mkdirat(namespaceDescriptor, $0, S_IRWXU)
      }
      if result != 0 {
        guard errno == EEXIST else {
          throw MLXLocalInferenceProviderError.invalidModelConfiguration
        }
        continue
      }
      let snapshotDescriptor = name.withCString {
        openat(
          namespaceDescriptor,
          $0,
          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
      }
      guard snapshotDescriptor >= 0 else {
        throw MLXLocalInferenceProviderError.invalidModelConfiguration
      }
      var status = stat()
      guard
        fstat(snapshotDescriptor, &status) == 0,
        status.st_mode & S_IFMT == S_IFDIR,
        status.st_uid == geteuid(),
        status.st_mode & mode_t(0o7777) == mode_t(0o700),
        UInt64(status.st_nlink) == 2
      else {
        close(snapshotDescriptor)
        throw MLXLocalInferenceProviderError.invalidModelConfiguration
      }
      return (
        directory.appending(path: name, directoryHint: .isDirectory),
        snapshotDescriptor
      )
    }
    throw MLXLocalInferenceProviderError.invalidModelConfiguration
  }

  private func validateNamespace(_ fileDescriptor: Int32) throws {
    var status = stat()
    guard
      fstat(fileDescriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFDIR,
      status.st_uid == geteuid(),
      status.st_mode & mode_t(0o7777) == mode_t(0o700),
      UInt64(status.st_nlink) <= UInt64(snapshotLimit + 2),
      try entryNames(in: fileDescriptor).allSatisfy({ name in
        guard
          name.hasPrefix("snapshot-"),
          let index = Int(name.dropFirst("snapshot-".count)),
          name == "snapshot-\(index)"
        else {
          return false
        }
        return (0..<snapshotLimit).contains(index)
      })
    else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
  }

  private func entryNames(in fileDescriptor: Int32) throws -> [String] {
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
    return names
  }
}
