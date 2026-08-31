import Darwin
import Foundation
import HexProviders

struct MLXModelArtifactSnapshotBuilder: Sendable {
  private let namespace: MLXModelArtifactSnapshotNamespace
  private let cloneArtifact: @Sendable (Int32, Int32, String) -> Int32

  init(
    namespace: MLXModelArtifactSnapshotNamespace = MLXModelArtifactSnapshotNamespace(),
    cloneArtifact: @escaping @Sendable (Int32, Int32, String) -> Int32 = {
      sourceDescriptor,
      destinationDescriptor,
      name in
      name.withCString {
        fclonefileat(sourceDescriptor, destinationDescriptor, $0, 0)
      }
    }
  ) {
    self.namespace = namespace
    self.cloneArtifact = cloneArtifact
  }

  func makeSnapshot(
    for configuration: MLXLocalModelConfiguration
  ) throws -> MLXModelArtifactSnapshot {
    try Task.checkCancellation()
    guard configuration.hasOriginalDirectoryIdentity() else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    let sourceDescriptor = configuration.directory.path.withCString {
      open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard
      sourceDescriptor >= 0,
      configuration.hasOriginalDirectoryIdentity(fileDescriptor: sourceDescriptor)
    else {
      if sourceDescriptor >= 0 {
        close(sourceDescriptor)
      }
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    defer { close(sourceDescriptor) }

    let initialNames = try artifactNames(in: sourceDescriptor)
    let artifacts = try openArtifacts(
      named: initialNames,
      in: sourceDescriptor,
      policy: configuration.resourcePolicy
    )
    defer {
      for artifact in artifacts {
        close(artifact.fileDescriptor)
      }
    }
    try validateManifest(artifacts)

    let snapshotLocation = try namespace.makeSnapshotDirectory()
    let snapshotDirectory = snapshotLocation.directory
    let destinationDescriptor = snapshotLocation.fileDescriptor
    let claim = snapshotLocation.claim
    var snapshotEntries: [MLXModelArtifactSnapshotEntry] = []
    var preserveSnapshot = false
    defer {
      if !preserveSnapshot {
        for entry in snapshotEntries {
          _ = ftruncate(entry.fileDescriptor, 0)
          _ = fsync(entry.fileDescriptor)
          _ = fchmod(entry.fileDescriptor, 0)
          close(entry.fileDescriptor)
        }
        _ = fchmod(destinationDescriptor, 0)
        close(destinationDescriptor)
        close(claim.fileDescriptor)
      }
    }

    for artifact in artifacts {
      try Task.checkCancellation()
      snapshotEntries.append(try snapshot(artifact, into: destinationDescriptor))
    }
    try validateSourceStillMatches(
      artifacts,
      sourceDescriptor: sourceDescriptor,
      initialNames: initialNames
    )
    var directoryStatus = stat()
    guard
      fchmod(destinationDescriptor, 0o500) == 0,
      fstat(destinationDescriptor, &directoryStatus) == 0,
      directoryStatus.st_mode & S_IFMT == S_IFDIR,
      directoryStatus.st_uid == geteuid(),
      directoryStatus.st_mode & mode_t(0o7777) == mode_t(0o500),
      UInt64(directoryStatus.st_nlink) == UInt64(snapshotEntries.count + 2)
    else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    let directoryIdentity = try MLXModelArtifactSnapshotIdentity(status: directoryStatus)
    let snapshot = MLXModelArtifactSnapshot(
      directory: snapshotDirectory,
      directoryDescriptor: destinationDescriptor,
      directoryIdentity: directoryIdentity,
      entries: snapshotEntries,
      claim: claim
    )
    preserveSnapshot = true
    try snapshot.validateBoundPath()
    return snapshot
  }

  private func artifactNames(in directoryDescriptor: Int32) throws -> [String] {
    let enumerationDescriptor = ".".withCString {
      openat(directoryDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
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
      var nameStorage = entry.pointee.d_name
      let bytes = withUnsafeBytes(of: &nameStorage) { buffer in
        Array(buffer.prefix(length))
      }
      guard let name = String(bytes: bytes, encoding: .utf8) else {
        throw MLXLocalInferenceProviderError.invalidModelConfiguration
      }
      if name == "." || name == ".." {
        continue
      }
      guard
        !name.isEmpty,
        name.utf8.count <= 255,
        !name.contains("/"),
        !name.contains("\0")
      else {
        throw MLXLocalInferenceProviderError.invalidModelConfiguration
      }
      names.append(name)
    }
    guard errno == 0 else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    return names.sorted()
  }

  private func openArtifacts(
    named names: [String],
    in directoryDescriptor: Int32,
    policy: MLXLocalModelResourcePolicy
  ) throws -> [MLXModelArtifact] {
    guard
      names.count >= 3,
      names.count <= policy.maximumArtifactCount
    else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    var artifacts: [MLXModelArtifact] = []
    var totalBytes: UInt64 = 0
    do {
      for name in names {
        try Task.checkCancellation()
        guard Self.isAllowedArtifactName(name) else {
          throw MLXLocalInferenceProviderError.invalidModelConfiguration
        }
        var pathStatus = stat()
        let pathResult = name.withCString {
          fstatat(directoryDescriptor, $0, &pathStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard pathResult == 0, pathStatus.st_mode & S_IFMT == S_IFREG else {
          throw MLXLocalInferenceProviderError.invalidModelConfiguration
        }
        let fileDescriptor = name.withCString {
          openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fileDescriptor >= 0 else {
          throw MLXLocalInferenceProviderError.invalidModelConfiguration
        }
        var descriptorStatus = stat()
        guard
          fstat(fileDescriptor, &descriptorStatus) == 0,
          descriptorStatus.st_mode & S_IFMT == S_IFREG,
          descriptorStatus.st_dev == pathStatus.st_dev,
          descriptorStatus.st_ino == pathStatus.st_ino
        else {
          close(fileDescriptor)
          throw MLXLocalInferenceProviderError.invalidModelConfiguration
        }
        do {
          let artifact = try MLXModelArtifact(
            name: name,
            fileDescriptor: fileDescriptor,
            status: descriptorStatus
          )
          if name.hasSuffix(".json") || name.hasSuffix(".jinja") {
            guard artifact.size <= policy.maximumControlFileBytes else {
              throw MLXLocalInferenceProviderError.invalidModelConfiguration
            }
          }
          let (candidateBytes, overflowed) = totalBytes.addingReportingOverflow(artifact.size)
          guard !overflowed, candidateBytes <= policy.maximumArtifactBytes else {
            throw MLXLocalInferenceProviderError.invalidModelConfiguration
          }
          totalBytes = candidateBytes
          artifacts.append(artifact)
        } catch {
          close(fileDescriptor)
          throw error
        }
      }
      return artifacts
    } catch {
      for artifact in artifacts {
        close(artifact.fileDescriptor)
      }
      throw error
    }
  }

  private func validateManifest(_ artifacts: [MLXModelArtifact]) throws {
    let names = Set(artifacts.map(\.name))
    guard
      names.contains("config.json"),
      names.contains("tokenizer.json"),
      names.contains(where: { $0.hasSuffix(".safetensors") })
    else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
  }

  private func snapshot(
    _ artifact: MLXModelArtifact,
    into destinationDescriptor: Int32
  ) throws -> MLXModelArtifactSnapshotEntry {
    try Task.checkCancellation()
    let cloneResult = cloneArtifact(
      artifact.fileDescriptor,
      destinationDescriptor,
      artifact.name
    )
    let destinationFileDescriptor =
      if cloneResult == 0 {
        try openWritableClone(artifact, in: destinationDescriptor)
      } else {
        try copy(artifact, into: destinationDescriptor)
      }
    var preserveDescriptor = false
    defer {
      if !preserveDescriptor {
        _ = ftruncate(destinationFileDescriptor, 0)
        _ = fsync(destinationFileDescriptor)
        close(destinationFileDescriptor)
      }
    }

    var destinationStatus = stat()
    guard
      fstat(destinationFileDescriptor, &destinationStatus) == 0,
      destinationStatus.st_mode & S_IFMT == S_IFREG,
      destinationStatus.st_uid == geteuid(),
      UInt64(destinationStatus.st_nlink) == 1,
      destinationStatus.st_size >= 0,
      UInt64(destinationStatus.st_size) == artifact.size,
      fchmod(destinationFileDescriptor, 0o400) == 0,
      fsync(destinationFileDescriptor) == 0,
      fstat(destinationFileDescriptor, &destinationStatus) == 0,
      destinationStatus.st_mode & S_IFMT == S_IFREG,
      destinationStatus.st_uid == geteuid(),
      destinationStatus.st_mode & mode_t(0o7777) == mode_t(0o400),
      UInt64(destinationStatus.st_nlink) == 1,
      destinationStatus.st_size >= 0,
      UInt64(destinationStatus.st_size) == artifact.size
    else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    let identity = try MLXModelArtifactSnapshotIdentity(status: destinationStatus)
    preserveDescriptor = true
    return MLXModelArtifactSnapshotEntry(
      name: artifact.name,
      fileDescriptor: destinationFileDescriptor,
      identity: identity
    )
  }

  private func openWritableClone(
    _ artifact: MLXModelArtifact,
    in destinationDescriptor: Int32
  ) throws -> Int32 {
    let readDescriptor = artifact.name.withCString {
      openat(destinationDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard readDescriptor >= 0 else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    defer { close(readDescriptor) }
    var readStatus = stat()
    guard
      fstat(readDescriptor, &readStatus) == 0,
      readStatus.st_mode & S_IFMT == S_IFREG,
      readStatus.st_uid == geteuid(),
      UInt64(readStatus.st_nlink) == 1,
      readStatus.st_size >= 0,
      UInt64(readStatus.st_size) == artifact.size,
      fchmod(readDescriptor, 0o600) == 0
    else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    let writableDescriptor = artifact.name.withCString {
      openat(destinationDescriptor, $0, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    }
    guard writableDescriptor >= 0 else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    var writableStatus = stat()
    guard
      fstat(writableDescriptor, &writableStatus) == 0,
      writableStatus.st_dev == readStatus.st_dev,
      writableStatus.st_ino == readStatus.st_ino
    else {
      close(writableDescriptor)
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    return writableDescriptor
  }

  private func copy(
    _ artifact: MLXModelArtifact,
    into destinationDescriptor: Int32
  ) throws -> Int32 {
    guard lseek(artifact.fileDescriptor, 0, SEEK_SET) == 0 else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    let destinationFileDescriptor = artifact.name.withCString {
      openat(
        destinationDescriptor,
        $0,
        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC,
        S_IRUSR | S_IWUSR
      )
    }
    guard destinationFileDescriptor >= 0 else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    var preserveDescriptor = false
    defer {
      if !preserveDescriptor {
        _ = ftruncate(destinationFileDescriptor, 0)
        _ = fsync(destinationFileDescriptor)
        close(destinationFileDescriptor)
      }
    }

    var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
    var copiedBytes: UInt64 = 0
    while copiedBytes < artifact.size {
      try Task.checkCancellation()
      let remaining = artifact.size - copiedBytes
      let requested = min(buffer.count, Int(remaining))
      let readCount = buffer.withUnsafeMutableBytes { bytes -> Int in
        guard let baseAddress = bytes.baseAddress else {
          return -1
        }
        return Darwin.read(artifact.fileDescriptor, baseAddress, requested)
      }
      guard readCount > 0 else {
        throw MLXLocalInferenceProviderError.invalidModelConfiguration
      }
      var written = 0
      while written < readCount {
        let writeCount = buffer.withUnsafeBytes { bytes -> Int in
          guard let baseAddress = bytes.baseAddress else {
            return -1
          }
          return Darwin.write(
            destinationFileDescriptor,
            baseAddress.advanced(by: written),
            readCount - written
          )
        }
        guard writeCount > 0 else {
          throw MLXLocalInferenceProviderError.invalidModelConfiguration
        }
        written += writeCount
      }
      copiedBytes += UInt64(readCount)
    }
    var extraByte: UInt8 = 0
    guard
      Darwin.read(artifact.fileDescriptor, &extraByte, 1) == 0,
      fsync(destinationFileDescriptor) == 0
    else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    preserveDescriptor = true
    return destinationFileDescriptor
  }

  private func validateSourceStillMatches(
    _ artifacts: [MLXModelArtifact],
    sourceDescriptor: Int32,
    initialNames: [String]
  ) throws {
    guard try artifactNames(in: sourceDescriptor) == initialNames else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    for artifact in artifacts {
      try Task.checkCancellation()
      var descriptorStatus = stat()
      var pathStatus = stat()
      let pathResult = artifact.name.withCString {
        fstatat(sourceDescriptor, $0, &pathStatus, AT_SYMLINK_NOFOLLOW)
      }
      guard
        fstat(artifact.fileDescriptor, &descriptorStatus) == 0,
        pathResult == 0,
        artifact.matches(descriptorStatus),
        artifact.matches(pathStatus)
      else {
        throw MLXLocalInferenceProviderError.invalidModelConfiguration
      }
    }
  }

  private static func isAllowedArtifactName(_ name: String) -> Bool {
    name.hasSuffix(".safetensors")
      || name.hasSuffix(".json")
      || name.hasSuffix(".jinja")
  }
}
