import Darwin
import Foundation
import HexProviders

struct MLXModelArtifactSnapshotBuilder: Sendable {
  private let namespace: MLXModelArtifactSnapshotNamespace
  private let copyArtifact: @Sendable (Int32, Int32, UInt64) throws -> Void

  init(
    namespace: MLXModelArtifactSnapshotNamespace = MLXModelArtifactSnapshotNamespace(),
    copyArtifact: @escaping @Sendable (Int32, Int32, UInt64) throws -> Void = {
      sourceDescriptor,
      destinationDescriptor,
      byteCount in
      try MLXModelArtifactSnapshotBuilder.copyPinnedArtifact(
        sourceDescriptor: sourceDescriptor,
        destinationDescriptor: destinationDescriptor,
        byteCount: byteCount
      )
    }
  ) {
    self.namespace = namespace
    self.copyArtifact = copyArtifact
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

    let maximumArtifactCount = configuration.resourcePolicy.maximumArtifactCount
    let initialNames = try artifactNames(
      in: sourceDescriptor,
      maximumCount: maximumArtifactCount
    )
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
          Self.discardOwnedFileDescriptor(entry.fileDescriptor)
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
      configuration: configuration,
      artifacts: artifacts,
      sourceDescriptor: sourceDescriptor,
      initialNames: initialNames,
      maximumArtifactCount: maximumArtifactCount
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

  private func artifactNames(
    in directoryDescriptor: Int32,
    maximumCount: Int
  ) throws -> [String] {
    guard maximumCount >= 0 else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
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
    let enumerationCapacity = maximumCount == Int.max ? Int.max : maximumCount + 1
    names.reserveCapacity(min(enumerationCapacity, 64))
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
      guard names.count <= maximumCount else {
        throw MLXLocalInferenceProviderError.invalidModelConfiguration
      }
      names.append(name)
      if names.count > maximumCount {
        throw MLXLocalInferenceProviderError.invalidModelConfiguration
      }
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
    let destination = try openDestination(named: artifact.name, in: destinationDescriptor)
    let destinationFileDescriptor = destination.fileDescriptor
    var preserveDescriptor = false
    defer {
      if !preserveDescriptor {
        Self.discardOwnedFileDescriptor(destinationFileDescriptor)
      }
    }

    try copyArtifact(
      artifact.fileDescriptor,
      destinationFileDescriptor,
      artifact.size
    )
    var destinationStatus = stat()
    guard
      fstat(destinationFileDescriptor, &destinationStatus) == 0,
      destinationStatus.st_mode & S_IFMT == S_IFREG,
      destinationStatus.st_uid == geteuid(),
      UInt64(destinationStatus.st_nlink) == 1,
      UInt64(destinationStatus.st_dev) == destination.device,
      UInt64(destinationStatus.st_ino) == destination.inode,
      destinationStatus.st_size >= 0,
      UInt64(destinationStatus.st_size) == artifact.size,
      fchmod(destinationFileDescriptor, 0o400) == 0,
      fsync(destinationFileDescriptor) == 0,
      fstat(destinationFileDescriptor, &destinationStatus) == 0,
      destinationStatus.st_mode & S_IFMT == S_IFREG,
      destinationStatus.st_uid == geteuid(),
      destinationStatus.st_mode & mode_t(0o7777) == mode_t(0o400),
      UInt64(destinationStatus.st_nlink) == 1,
      UInt64(destinationStatus.st_dev) == destination.device,
      UInt64(destinationStatus.st_ino) == destination.inode,
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

  private func openDestination(
    named name: String,
    in destinationDescriptor: Int32
  ) throws -> (fileDescriptor: Int32, device: UInt64, inode: UInt64) {
    let fileDescriptor = name.withCString {
      openat(
        destinationDescriptor,
        $0,
        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        S_IRUSR | S_IWUSR
      )
    }
    guard fileDescriptor >= 0 else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    var preserveDescriptor = false
    defer {
      if !preserveDescriptor {
        Self.discardOwnedFileDescriptor(fileDescriptor)
      }
    }

    var status = stat()
    guard
      fstat(fileDescriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(),
      status.st_mode & mode_t(0o7777) == mode_t(0o600),
      UInt64(status.st_nlink) == 1,
      status.st_size == 0
    else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    let device = UInt64(status.st_dev)
    let inode = UInt64(status.st_ino)
    guard
      fchmod(fileDescriptor, S_IRUSR | S_IWUSR) == 0,
      fsync(fileDescriptor) == 0,
      fstat(fileDescriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(),
      status.st_mode & mode_t(0o7777) == mode_t(0o600),
      UInt64(status.st_nlink) == 1,
      UInt64(status.st_dev) == device,
      UInt64(status.st_ino) == inode,
      status.st_size == 0
    else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    preserveDescriptor = true
    return (fileDescriptor, device, inode)
  }

  private static func copyPinnedArtifact(
    sourceDescriptor: Int32,
    destinationDescriptor: Int32,
    byteCount: UInt64
  ) throws {
    guard lseek(sourceDescriptor, 0, SEEK_SET) == 0 else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }

    var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
    var copiedBytes: UInt64 = 0
    while copiedBytes < byteCount {
      try Task.checkCancellation()
      let remaining = byteCount - copiedBytes
      let requested = min(buffer.count, Int(remaining))
      let readCount = buffer.withUnsafeMutableBytes { bytes -> Int in
        guard let baseAddress = bytes.baseAddress else {
          return -1
        }
        return Darwin.read(sourceDescriptor, baseAddress, requested)
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
            destinationDescriptor,
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
      Darwin.read(sourceDescriptor, &extraByte, 1) == 0,
      fsync(destinationDescriptor) == 0
    else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
  }

  private static func discardOwnedFileDescriptor(_ fileDescriptor: Int32) {
    _ = ftruncate(fileDescriptor, 0)
    _ = fchmod(fileDescriptor, 0)
    _ = fsync(fileDescriptor)
    close(fileDescriptor)
  }

  private func validateSourceStillMatches(
    configuration: MLXLocalModelConfiguration,
    artifacts: [MLXModelArtifact],
    sourceDescriptor: Int32,
    initialNames: [String],
    maximumArtifactCount: Int
  ) throws {
    guard
      configuration.hasOriginalDirectoryIdentity(),
      configuration.hasOriginalDirectoryIdentity(fileDescriptor: sourceDescriptor),
      try artifactNames(
        in: sourceDescriptor,
        maximumCount: maximumArtifactCount
      ) == initialNames
    else {
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
