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

  func makeSnapshotDirectory() throws -> (
    directory: URL,
    fileDescriptor: Int32,
    claim: MLXModelArtifactSnapshotClaim
  ) {
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
      guard let claim = try makeClaim(index: index, in: namespaceDescriptor) else {
        continue
      }
      let name = "snapshot-\(index)"
      let result = name.withCString {
        mkdirat(namespaceDescriptor, $0, S_IRWXU)
      }
      guard result == 0, fsync(namespaceDescriptor) == 0 else {
        close(claim.fileDescriptor)
        throw MLXLocalInferenceProviderError.invalidModelConfiguration
      }
      let snapshotDescriptor = name.withCString {
        openat(
          namespaceDescriptor,
          $0,
          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
      }
      guard snapshotDescriptor >= 0 else {
        close(claim.fileDescriptor)
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
        close(claim.fileDescriptor)
        throw MLXLocalInferenceProviderError.invalidModelConfiguration
      }
      return (
        directory.appending(path: name, directoryHint: .isDirectory),
        snapshotDescriptor,
        claim
      )
    }
    throw MLXLocalInferenceProviderError.invalidModelConfiguration
  }

  private func validateNamespace(_ fileDescriptor: Int32) throws {
    var status = stat()
    let names = try entryNames(in: fileDescriptor)
    guard
      fstat(fileDescriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFDIR,
      status.st_uid == geteuid(),
      status.st_mode & mode_t(0o7777) == mode_t(0o700),
      names.count <= snapshotLimit * 2,
      UInt64(status.st_nlink) >= 2,
      UInt64(status.st_nlink) <= UInt64(snapshotLimit * 2 + 2),
      names.allSatisfy({ isReservationName($0) })
    else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }

    let nameSet = Set(names)
    for index in 0..<snapshotLimit {
      let claimName = "claim-\(index)"
      let snapshotName = "snapshot-\(index)"
      let hasClaim = nameSet.contains(claimName)
      let hasSnapshot = nameSet.contains(snapshotName)
      if hasClaim {
        try validateClaim(named: claimName, in: fileDescriptor)
      }
      if hasSnapshot {
        if !hasClaim {
          try validateClaim(named: claimName, in: fileDescriptor)
        }
        try validateSnapshotReservation(named: snapshotName, in: fileDescriptor)
      }
    }
  }

  private func makeClaim(
    index: Int,
    in namespaceDescriptor: Int32
  ) throws -> MLXModelArtifactSnapshotClaim? {
    let name = "claim-\(index)"
    let claimDescriptor = name.withCString {
      openat(
        namespaceDescriptor,
        $0,
        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        S_IRUSR | S_IWUSR
      )
    }
    guard claimDescriptor >= 0 else {
      guard errno == EEXIST else {
        throw MLXLocalInferenceProviderError.invalidModelConfiguration
      }
      try validateClaim(named: name, in: namespaceDescriptor)
      return nil
    }
    var preserveDescriptor = false
    defer {
      if !preserveDescriptor {
        close(claimDescriptor)
      }
    }

    var status = stat()
    guard
      fstat(claimDescriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(),
      status.st_mode & mode_t(0o7777) == mode_t(0o600),
      UInt64(status.st_nlink) == 1,
      status.st_size == 0,
      fchmod(claimDescriptor, S_IRUSR) == 0,
      fsync(claimDescriptor) == 0,
      fsync(namespaceDescriptor) == 0,
      fstat(claimDescriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(),
      status.st_mode & mode_t(0o7777) == mode_t(0o400),
      UInt64(status.st_nlink) == 1,
      status.st_size == 0
    else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    let claim = try MLXModelArtifactSnapshotClaim(
      url: directory.appending(path: name),
      fileDescriptor: claimDescriptor,
      identity: MLXModelArtifactSnapshotIdentity(status: status)
    )
    preserveDescriptor = true
    return claim
  }

  private func validateClaim(named name: String, in fileDescriptor: Int32) throws {
    var status = stat()
    let result = name.withCString {
      fstatat(fileDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
    }
    let permissions = status.st_mode & mode_t(0o7777)
    guard
      result == 0,
      status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(),
      permissions == mode_t(0o400) || permissions == mode_t(0o600),
      UInt64(status.st_nlink) == 1,
      status.st_size == 0
    else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
  }

  private func validateSnapshotReservation(
    named name: String,
    in fileDescriptor: Int32
  ) throws {
    var status = stat()
    let result = name.withCString {
      fstatat(fileDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
    }
    let permissions = status.st_mode & mode_t(0o7777)
    guard
      result == 0,
      status.st_mode & S_IFMT == S_IFDIR,
      status.st_uid == geteuid(),
      permissions == 0 || permissions == mode_t(0o500) || permissions == mode_t(0o700),
      UInt64(status.st_nlink) >= 2
    else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
  }

  private func isReservationName(_ name: String) -> Bool {
    for prefix in ["claim-", "snapshot-"] where name.hasPrefix(prefix) {
      guard
        let index = Int(name.dropFirst(prefix.count)),
        name == "\(prefix)\(index)"
      else {
        return false
      }
      return (0..<snapshotLimit).contains(index)
    }
    return false
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
