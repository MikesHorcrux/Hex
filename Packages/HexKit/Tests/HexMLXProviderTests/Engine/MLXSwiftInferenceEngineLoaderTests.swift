import Darwin
import Foundation
import HexCore
import HexProviders
import Testing

@testable import HexMLXProvider

@Suite("MLX Swift inference engine loader")
struct MLXSwiftInferenceEngineLoaderTests {
  @Test
  func rejectsSnapshotDirectoryReplacedDuringContainerLoad() async throws {
    let root = try makeRoot()
    let modelDirectory = root.appending(path: "model", directoryHint: .isDirectory)
    try makeCompleteModelDirectory(at: modelDirectory)
    let configuration = try makeConfiguration(directory: modelDirectory)
    let capturedSnapshot = root.appending(
      path: "captured-snapshot",
      directoryHint: .isDirectory
    )
    defer {
      try? makeDirectoryWritable(capturedSnapshot)
      try? FileManager.default.removeItem(at: root)
    }
    let replacementConfiguration = Data("{\"replacement\":true}".utf8)
    let recorder = ReplacementLoadRecorder()
    let loader = MLXSwiftInferenceEngineLoader(
      loadContainer: { directory in
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o700],
          ofItemAtPath: directory.path
        )
        try FileManager.default.moveItem(at: directory, to: capturedSnapshot)
        try FileManager.default.createDirectory(
          at: directory,
          withIntermediateDirectories: false
        )
        try replacementConfiguration.write(
          to: directory.appending(path: "config.json")
        )
        try Data("{}".utf8).write(to: directory.appending(path: "tokenizer.json"))
        try Data("replacement-weights".utf8).write(
          to: directory.appending(path: "model.safetensors")
        )
        let observedConfiguration = try Data(
          contentsOf: directory.appending(path: "config.json")
        )
        await recorder.record(
          directory: directory,
          observedConfiguration: observedConfiguration
        )
        throw StubError.unexpectedLoad
      },
      snapshotBuilder: try makeSnapshotBuilder(root: root)
    )

    await #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try await loader.loadModel(configuration)
    }
    let replacementDirectory = try #require(await recorder.directory())
    defer { try? FileManager.default.removeItem(at: replacementDirectory) }
    #expect(await recorder.observedConfiguration() == replacementConfiguration)
    #expect(
      try Data(contentsOf: replacementDirectory.appending(path: "config.json"))
        == replacementConfiguration
    )
    try makeDirectoryWritable(capturedSnapshot)
    #expect(try fileSize(capturedSnapshot.appending(path: "config.json")) == 0)
    #expect(try fileSize(capturedSnapshot.appending(path: "tokenizer.json")) == 0)
    #expect(try fileSize(capturedSnapshot.appending(path: "model.safetensors")) == 0)
  }

  @Test
  func snapshotCleanupPreservesAReplacementDirectory() throws {
    let root = try makeRoot()
    let modelDirectory = root.appending(path: "model", directoryHint: .isDirectory)
    try makeCompleteModelDirectory(at: modelDirectory)
    let movedSnapshot = root.appending(
      path: "moved-snapshot",
      directoryHint: .isDirectory
    )
    defer {
      try? makeDirectoryWritable(movedSnapshot)
      try? FileManager.default.removeItem(at: root)
    }
    let sentinel = Data("unrelated-directory".utf8)

    let replacedPath = try releaseSnapshotAfterReplacingPath(
      configuration: makeConfiguration(directory: modelDirectory),
      movedSnapshot: movedSnapshot,
      replacement: .directory(sentinel),
      builder: makeSnapshotBuilder(root: root)
    )
    defer { try? FileManager.default.removeItem(at: replacedPath) }

    #expect(
      try Data(contentsOf: replacedPath.appending(path: "sentinel")) == sentinel
    )
    try makeDirectoryWritable(movedSnapshot)
    #expect(try fileSize(movedSnapshot.appending(path: "model.safetensors")) == 0)
  }

  @Test
  func snapshotCleanupPreservesAReplacementFile() throws {
    let root = try makeRoot()
    let modelDirectory = root.appending(path: "model", directoryHint: .isDirectory)
    try makeCompleteModelDirectory(at: modelDirectory)
    let movedSnapshot = root.appending(
      path: "moved-snapshot",
      directoryHint: .isDirectory
    )
    defer {
      try? makeDirectoryWritable(movedSnapshot)
      try? FileManager.default.removeItem(at: root)
    }
    let sentinel = Data("unrelated-file".utf8)

    let replacedPath = try releaseSnapshotAfterReplacingPath(
      configuration: makeConfiguration(directory: modelDirectory),
      movedSnapshot: movedSnapshot,
      replacement: .file(sentinel),
      builder: makeSnapshotBuilder(root: root)
    )
    defer { try? FileManager.default.removeItem(at: replacedPath) }

    #expect(try Data(contentsOf: replacedPath) == sentinel)
    try makeDirectoryWritable(movedSnapshot)
    #expect(try fileSize(movedSnapshot.appending(path: "model.safetensors")) == 0)
  }

  @Test
  func refusesSnapshotsAfterTheRuntimeResidueLimit() throws {
    let root = try makeRoot()
    let modelDirectory = root.appending(path: "model", directoryHint: .isDirectory)
    try makeCompleteModelDirectory(at: modelDirectory)
    let namespaceDirectory = root.appending(
      path: "snapshot-namespace",
      directoryHint: .isDirectory
    )
    defer {
      try? makeNamespaceWritable(namespaceDirectory)
      try? FileManager.default.removeItem(at: root)
    }
    let namespace = try MLXModelArtifactSnapshotNamespace(
      directory: namespaceDirectory,
      snapshotLimit: 2
    )
    let builder = MLXModelArtifactSnapshotBuilder(namespace: namespace)
    let configuration = try makeConfiguration(directory: modelDirectory)

    try exhaustSnapshotCapacity(builder: builder, configuration: configuration)

    let names = try FileManager.default.contentsOfDirectory(atPath: namespaceDirectory.path)
    #expect(
      Set(names) == ["claim-0", "snapshot-0", "claim-1", "snapshot-1"]
    )
  }

  @Test
  func movedSnapshotSlotsRemainConsumedAndBoundTheRuntimeResidue() throws {
    let root = try makeRoot()
    let modelDirectory = root.appending(path: "model", directoryHint: .isDirectory)
    try makeCompleteModelDirectory(at: modelDirectory)
    let namespaceDirectory = root.appending(
      path: "snapshot-namespace",
      directoryHint: .isDirectory
    )
    let firstMovedSnapshot = root.appending(
      path: "first-moved-snapshot",
      directoryHint: .isDirectory
    )
    let secondMovedSnapshot = root.appending(
      path: "second-moved-snapshot",
      directoryHint: .isDirectory
    )
    defer {
      try? makeNamespaceWritable(namespaceDirectory)
      try? makeDirectoryWritable(firstMovedSnapshot)
      try? makeDirectoryWritable(secondMovedSnapshot)
      try? FileManager.default.removeItem(at: root)
    }
    let namespace = try MLXModelArtifactSnapshotNamespace(
      directory: namespaceDirectory,
      snapshotLimit: 2
    )
    let builder = MLXModelArtifactSnapshotBuilder(namespace: namespace)
    let configuration = try makeConfiguration(directory: modelDirectory)

    let firstDirectory = try moveAndReleaseSnapshot(
      builder: builder,
      configuration: configuration,
      destination: firstMovedSnapshot
    )
    let secondDirectory = try moveAndReleaseSnapshot(
      builder: builder,
      configuration: configuration,
      destination: secondMovedSnapshot
    )

    #expect(secondDirectory != firstDirectory)
    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try builder.makeSnapshot(for: configuration)
    }
  }

  @Test
  func concurrentBuildersAtomicallyClaimUniqueSlots() async throws {
    let root = try makeRoot()
    let modelDirectory = root.appending(path: "model", directoryHint: .isDirectory)
    try makeCompleteModelDirectory(at: modelDirectory)
    let namespaceDirectory = root.appending(
      path: "snapshot-namespace",
      directoryHint: .isDirectory
    )
    defer {
      try? makeNamespaceWritable(namespaceDirectory)
      try? FileManager.default.removeItem(at: root)
    }
    let namespace = try MLXModelArtifactSnapshotNamespace(
      directory: namespaceDirectory,
      snapshotLimit: 8
    )
    let configuration = try makeConfiguration(directory: modelDirectory)

    let snapshots = try await withThrowingTaskGroup(
      of: MLXModelArtifactSnapshot.self,
      returning: [MLXModelArtifactSnapshot].self
    ) { group in
      for _ in 0..<8 {
        group.addTask {
          try MLXModelArtifactSnapshotBuilder(namespace: namespace).makeSnapshot(
            for: configuration
          )
        }
      }
      var snapshots: [MLXModelArtifactSnapshot] = []
      for try await snapshot in group {
        snapshots.append(snapshot)
      }
      return snapshots
    }

    #expect(Set(snapshots.map(\.directory)).count == 8)
    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try MLXModelArtifactSnapshotBuilder(namespace: namespace).makeSnapshot(
        for: configuration
      )
    }
    withExtendedLifetime(snapshots) {}
  }

  @Test
  func crossProcessClaimProbe() async throws {
    let environment = ProcessInfo.processInfo.environment
    let rootPath = environment["HEX_MLX_CROSS_PROCESS_PROBE_ROOT"]
    let workerID = environment["HEX_MLX_CROSS_PROCESS_PROBE_WORKER"]
    let mode = environment["HEX_MLX_CROSS_PROCESS_PROBE_MODE"]
    if rootPath == nil, workerID == nil, mode == nil {
      return
    }
    guard
      let rootPath,
      let workerID,
      let mode
    else {
      throw StubError.invalidProcessProbeMode
    }
    let root = URL(filePath: rootPath, directoryHint: .isDirectory)
    try Data(workerID.utf8).write(
      to: root.appending(path: "ready-\(workerID)")
    )
    let start = root.appending(path: "start")
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(60))
    while !FileManager.default.fileExists(atPath: start.path) {
      guard clock.now < deadline else {
        throw StubError.processProbeTimedOut
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    let namespace = try MLXModelArtifactSnapshotNamespace(
      directory: root.appending(
        path: "snapshot-namespace",
        directoryHint: .isDirectory
      ),
      snapshotLimit: 8
    )
    let builder = MLXModelArtifactSnapshotBuilder(namespace: namespace)
    let configuration = try makeConfiguration(
      directory: root.appending(path: "model", directoryHint: .isDirectory)
    )

    if mode == "claim" {
      let snapshot = try builder.makeSnapshot(for: configuration)
      try snapshot.validateBoundPath()
      withExtendedLifetime(snapshot) {}
    } else if mode == "refuse" {
      #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
        _ = try builder.makeSnapshot(for: configuration)
      }
    } else {
      throw StubError.invalidProcessProbeMode
    }
  }

  @Test
  func rejectsSnapshotReservationWithoutMatchingClaim() throws {
    let root = try makeRoot()
    let modelDirectory = root.appending(path: "model", directoryHint: .isDirectory)
    try makeCompleteModelDirectory(at: modelDirectory)
    let namespaceDirectory = root.appending(
      path: "snapshot-namespace",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: namespaceDirectory.appending(path: "snapshot-0"),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = try MLXModelArtifactSnapshotNamespace(
      directory: namespaceDirectory,
      snapshotLimit: 2
    )

    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try MLXModelArtifactSnapshotBuilder(namespace: namespace).makeSnapshot(
        for: makeConfiguration(directory: modelDirectory)
      )
    }
  }

  @Test
  func retainedClaimIdentityRejectsAReplacedClaimPath() throws {
    let root = try makeRoot()
    let modelDirectory = root.appending(path: "model", directoryHint: .isDirectory)
    try makeCompleteModelDirectory(at: modelDirectory)
    let namespaceDirectory = root.appending(
      path: "snapshot-namespace",
      directoryHint: .isDirectory
    )
    let movedClaim = root.appending(path: "moved-claim")
    defer {
      try? makeNamespaceWritable(namespaceDirectory)
      try? FileManager.default.removeItem(at: root)
    }
    let namespace = try MLXModelArtifactSnapshotNamespace(
      directory: namespaceDirectory,
      snapshotLimit: 2
    )
    let snapshot = try MLXModelArtifactSnapshotBuilder(namespace: namespace).makeSnapshot(
      for: makeConfiguration(directory: modelDirectory)
    )
    let claim = namespaceDirectory.appending(path: "claim-0")
    try FileManager.default.moveItem(at: claim, to: movedClaim)
    try Data().write(to: claim)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o400],
      ofItemAtPath: claim.path
    )

    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      try snapshot.validateBoundPath()
    }
  }

  @Test
  func materializationFailureAfterOpeningDestinationZeroesOwnedBytes() throws {
    let root = try makeRoot()
    let modelDirectory = root.appending(path: "model", directoryHint: .isDirectory)
    try makeCompleteModelDirectory(at: modelDirectory)
    let namespaceDirectory = root.appending(
      path: "snapshot-namespace",
      directoryHint: .isDirectory
    )
    let snapshotDirectory = namespaceDirectory.appending(
      path: "snapshot-0",
      directoryHint: .isDirectory
    )
    defer {
      try? makeNamespaceWritable(namespaceDirectory)
      try? FileManager.default.removeItem(at: root)
    }
    let marker = Data("{\"model_type\":\"test\"}".utf8)
    let namespace = try MLXModelArtifactSnapshotNamespace(
      directory: namespaceDirectory,
      snapshotLimit: 1
    )
    let builder = MLXModelArtifactSnapshotBuilder(
      namespace: namespace,
      copyArtifact: { _, destinationDescriptor, _ in
        let writeCount = marker.withUnsafeBytes { bytes -> Int in
          guard let baseAddress = bytes.baseAddress else {
            return -1
          }
          return Darwin.write(destinationDescriptor, baseAddress, bytes.count)
        }
        guard writeCount == marker.count else {
          throw MLXLocalInferenceProviderError.invalidModelConfiguration
        }
        errno = EMFILE
        throw MLXLocalInferenceProviderError.invalidModelConfiguration
      }
    )

    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try builder.makeSnapshot(for: makeConfiguration(directory: modelDirectory))
    }
    try makeDirectoryWritable(snapshotDirectory)
    let destination = snapshotDirectory.appending(path: "config.json")
    #expect(FileManager.default.fileExists(atPath: destination.path))
    #expect(try fileSize(destination) == 0)
    var status = stat()
    #expect(lstat(destination.path, &status) == 0)
    #expect(status.st_mode & S_IFMT == S_IFREG)
    #expect(status.st_mode & mode_t(0o7777) == 0)
  }

  @Test
  func rejectsHardLinkedSnapshotClaims() throws {
    let root = try makeRoot()
    let modelDirectory = root.appending(path: "model", directoryHint: .isDirectory)
    try makeCompleteModelDirectory(at: modelDirectory)
    let namespaceDirectory = root.appending(
      path: "snapshot-namespace",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: namespaceDirectory,
      withIntermediateDirectories: false
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: namespaceDirectory.path
    )
    let externalClaim = root.appending(path: "external-claim")
    try Data().write(to: externalClaim)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o400],
      ofItemAtPath: externalClaim.path
    )
    try FileManager.default.linkItem(
      at: externalClaim,
      to: namespaceDirectory.appending(path: "claim-0")
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = try MLXModelArtifactSnapshotNamespace(
      directory: namespaceDirectory,
      snapshotLimit: 2
    )

    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try MLXModelArtifactSnapshotBuilder(namespace: namespace).makeSnapshot(
        for: makeConfiguration(directory: modelDirectory)
      )
    }
  }

  @Test
  func rejectsHardLinkedSourceArtifacts() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let modelDirectory = root.appending(path: "model", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: false)
    try Data("{}".utf8).write(to: modelDirectory.appending(path: "config.json"))
    try Data("{}".utf8).write(to: modelDirectory.appending(path: "tokenizer.json"))
    let externalWeights = root.appending(path: "external-weights")
    try Data("weights".utf8).write(to: externalWeights)
    try FileManager.default.linkItem(
      at: externalWeights,
      to: modelDirectory.appending(path: "model.safetensors")
    )
    let configuration = try makeConfiguration(directory: modelDirectory)

    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try MLXModelArtifactSnapshotBuilder().makeSnapshot(for: configuration)
    }
  }

  @Test
  func rejectsAPathAliasAddedToASnapshotArtifact() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let modelDirectory = root.appending(path: "model", directoryHint: .isDirectory)
    try makeCompleteModelDirectory(at: modelDirectory)
    let snapshot = try makeSnapshotBuilder(root: root).makeSnapshot(
      for: makeConfiguration(directory: modelDirectory)
    )
    let alias = root.appending(path: "snapshot-config-alias")
    try FileManager.default.linkItem(
      at: snapshot.directory.appending(path: "config.json"),
      to: alias
    )

    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      try snapshot.validateBoundPath()
    }
  }

  @Test
  func rejectsAReplacedModelDirectoryBeforeLoadingFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "hex-mlx-loader-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let modelDirectory = root.appending(path: "model", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: modelDirectory,
      withIntermediateDirectories: true
    )
    let configuration = try MLXLocalModelConfiguration(
      modelID: ModelID(rawValue: "model"),
      displayName: "Model",
      directory: modelDirectory,
      maximumOutputTokens: 128
    )
    let movedDirectory = root.appending(path: "moved", directoryHint: .isDirectory)
    try FileManager.default.moveItem(at: modelDirectory, to: movedDirectory)
    try FileManager.default.createDirectory(
      at: modelDirectory,
      withIntermediateDirectories: false
    )

    await #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try await MLXSwiftInferenceEngineLoader(loadContainer: { _ in
        throw StubError.unexpectedLoad
      }).loadModel(configuration)
    }
  }

  @Test
  func rejectsSymlinkedArtifactsAndIncompleteManifestsBeforeLoading() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let modelDirectory = root.appending(path: "model", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: false)
    try Data("{}".utf8).write(to: modelDirectory.appending(path: "config.json"))
    try Data("{}".utf8).write(to: modelDirectory.appending(path: "tokenizer.json"))
    let weightBlob = root.appending(path: "weight-blob")
    try Data("weights".utf8).write(to: weightBlob)
    try FileManager.default.createSymbolicLink(
      at: modelDirectory.appending(path: "model.safetensors"),
      withDestinationURL: weightBlob
    )
    let configuration = try makeConfiguration(directory: modelDirectory)
    let recorder = LoadRecorder()
    let loader = MLXSwiftInferenceEngineLoader(loadContainer: { directory in
      await recorder.record(directory)
      throw StubError.unexpectedLoad
    })

    await #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try await loader.loadModel(configuration)
    }
    #expect(await recorder.count() == 0)

    try FileManager.default.removeItem(
      at: modelDirectory.appending(path: "model.safetensors")
    )
    await #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try await loader.loadModel(configuration)
    }
    #expect(await recorder.count() == 0)
  }

  @Test
  func snapshotsDescriptorOpenedArtifactsBeforeTheLoaderSeesThem() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let modelDirectory = root.appending(path: "model", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: false)
    let originalConfiguration = Data("{\"model_type\":\"test\"}".utf8)
    try originalConfiguration.write(to: modelDirectory.appending(path: "config.json"))
    try Data("{}".utf8).write(to: modelDirectory.appending(path: "tokenizer.json"))
    try Data("weights".utf8).write(
      to: modelDirectory.appending(path: "model.safetensors")
    )
    let configuration = try makeConfiguration(directory: modelDirectory)

    let snapshot = try makeSnapshotBuilder(root: root).makeSnapshot(for: configuration)
    try Data("mutated".utf8).write(to: modelDirectory.appending(path: "config.json"))

    var directoryStatus = stat()
    #expect(lstat(snapshot.directory.path, &directoryStatus) == 0)
    #expect(directoryStatus.st_mode & S_IFMT == S_IFDIR)
    #expect(directoryStatus.st_uid == geteuid())
    #expect(directoryStatus.st_mode & mode_t(0o7777) == mode_t(0o500))
    #expect(UInt64(directoryStatus.st_nlink) == 5)
    let namespaceDirectory = snapshot.directory.deletingLastPathComponent()
    var namespaceStatus = stat()
    #expect(lstat(namespaceDirectory.path, &namespaceStatus) == 0)
    #expect(namespaceStatus.st_mode & S_IFMT == S_IFDIR)
    #expect(namespaceStatus.st_uid == geteuid())
    #expect(namespaceStatus.st_mode & mode_t(0o7777) == mode_t(0o700))
    var claimStatus = stat()
    #expect(
      lstat(namespaceDirectory.appending(path: "claim-0").path, &claimStatus) == 0
    )
    #expect(claimStatus.st_mode & S_IFMT == S_IFREG)
    #expect(claimStatus.st_uid == geteuid())
    #expect(claimStatus.st_mode & mode_t(0o7777) == mode_t(0o400))
    #expect(UInt64(claimStatus.st_nlink) == 1)
    #expect(claimStatus.st_size == 0)
    var artifactStatus = stat()
    #expect(
      lstat(snapshot.directory.appending(path: "config.json").path, &artifactStatus) == 0
    )
    #expect(artifactStatus.st_mode & S_IFMT == S_IFREG)
    #expect(artifactStatus.st_uid == geteuid())
    #expect(artifactStatus.st_mode & mode_t(0o7777) == mode_t(0o400))
    #expect(UInt64(artifactStatus.st_nlink) == 1)

    #expect(
      try Data(contentsOf: snapshot.directory.appending(path: "config.json"))
        == originalConfiguration
    )
  }

  @Test
  func enforcesArtifactCountControlFileAndAggregateBudgets() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let modelDirectory = root.appending(path: "model", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: false)
    try Data(repeating: 1, count: 12).write(
      to: modelDirectory.appending(path: "config.json")
    )
    try Data(repeating: 2, count: 12).write(
      to: modelDirectory.appending(path: "tokenizer.json")
    )
    try Data(repeating: 3, count: 12).write(
      to: modelDirectory.appending(path: "model.safetensors")
    )
    let aggregatePolicy = try MLXLocalModelResourcePolicy(
      maximumArtifactBytes: 32,
      maximumControlFileBytes: 16,
      maximumArtifactCount: 3
    )
    let aggregateConfiguration = try makeConfiguration(
      directory: modelDirectory,
      resourcePolicy: aggregatePolicy
    )
    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try MLXModelArtifactSnapshotBuilder().makeSnapshot(for: aggregateConfiguration)
    }

    let controlPolicy = try MLXLocalModelResourcePolicy(
      maximumArtifactBytes: 64,
      maximumControlFileBytes: 8,
      maximumArtifactCount: 3
    )
    let controlConfiguration = try makeConfiguration(
      directory: modelDirectory,
      resourcePolicy: controlPolicy
    )
    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try MLXModelArtifactSnapshotBuilder().makeSnapshot(for: controlConfiguration)
    }
  }

  @Test
  func rejectsGroupWritableSourceArtifactsBeforeSnapshotting() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let modelDirectory = root.appending(path: "model", directoryHint: .isDirectory)
    try makeCompleteModelDirectory(at: modelDirectory)
    let writableArtifact = modelDirectory.appending(path: "config.json")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o664],
      ofItemAtPath: writableArtifact.path
    )

    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try makeSnapshotBuilder(root: root).makeSnapshot(
        for: makeConfiguration(directory: modelDirectory)
      )
    }
  }

  @Test
  func rejectsSourceDirectoryPermissionChangesBeforeSnapshotting() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let modelDirectory = root.appending(path: "model", directoryHint: .isDirectory)
    try makeCompleteModelDirectory(at: modelDirectory)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: modelDirectory.path
    )
    let configuration = try makeConfiguration(directory: modelDirectory)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o775],
      ofItemAtPath: modelDirectory.path
    )

    #expect(!configuration.hasOriginalDirectoryIdentity())
    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try makeSnapshotBuilder(root: root).makeSnapshot(for: configuration)
    }
  }

  @Test
  func rejectsSourceDirectoryPermissionChangesDuringSnapshotting() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let modelDirectory = root.appending(path: "model", directoryHint: .isDirectory)
    try makeCompleteModelDirectory(at: modelDirectory)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: modelDirectory.path
    )
    let configuration = try makeConfiguration(directory: modelDirectory)
    let builder = MLXModelArtifactSnapshotBuilder(
      namespace: try MLXModelArtifactSnapshotNamespace(
        directory: root.appending(path: "snapshot-namespace", directoryHint: .isDirectory),
        snapshotLimit: 1
      ),
      copyArtifact: { _, destinationDescriptor, byteCount in
        var remainingBytes = byteCount
        let buffer = [UInt8](repeating: 0, count: 1_024)
        while remainingBytes > 0 {
          let requestedBytes = min(remainingBytes, UInt64(buffer.count))
          var writtenBytes = 0
          while writtenBytes < Int(requestedBytes) {
            let writeCount = buffer.withUnsafeBytes { bytes -> Int in
              guard let baseAddress = bytes.baseAddress else {
                return -1
              }
              return Darwin.write(
                destinationDescriptor,
                baseAddress.advanced(by: writtenBytes),
                Int(requestedBytes) - writtenBytes
              )
            }
            guard writeCount > 0 else {
              throw MLXLocalInferenceProviderError.invalidModelConfiguration
            }
            writtenBytes += writeCount
          }
          remainingBytes -= UInt64(writtenBytes)
        }
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o775],
          ofItemAtPath: modelDirectory.path
        )
      }
    )

    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try builder.makeSnapshot(for: configuration)
    }
  }

  @Test
  func rejectsSourceEnumerationBeyondTheArtifactBound() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let modelDirectory = root.appending(path: "model", directoryHint: .isDirectory)
    try makeCompleteModelDirectory(at: modelDirectory)
    try Data("extra".utf8).write(to: modelDirectory.appending(path: "extra.json"))
    let policy = try MLXLocalModelResourcePolicy(
      maximumArtifactBytes: 64,
      maximumControlFileBytes: 64,
      maximumArtifactCount: 3
    )

    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try makeSnapshotBuilder(root: root).makeSnapshot(
        for: makeConfiguration(directory: modelDirectory, resourcePolicy: policy)
      )
    }
  }

  @Test
  func rejectsSourceArtifactModeChangesDuringSnapshot() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let modelDirectory = root.appending(path: "model", directoryHint: .isDirectory)
    try makeCompleteModelDirectory(at: modelDirectory)
    let configuration = try makeConfiguration(directory: modelDirectory)
    let sourceArtifact = modelDirectory.appending(path: "config.json")
    let builder = MLXModelArtifactSnapshotBuilder(
      namespace: try MLXModelArtifactSnapshotNamespace(
        directory: root.appending(path: "snapshot-namespace", directoryHint: .isDirectory),
        snapshotLimit: 1
      ),
      copyArtifact: { sourceDescriptor, destinationDescriptor, byteCount in
        var copiedBytes: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while copiedBytes < byteCount {
          let requested = min(buffer.count, Int(byteCount - copiedBytes))
          let readCount = buffer.withUnsafeMutableBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else {
              return -1
            }
            return Darwin.read(sourceDescriptor, baseAddress, requested)
          }
          guard readCount > 0 else {
            throw MLXLocalInferenceProviderError.invalidModelConfiguration
          }
          var writtenBytes = 0
          while writtenBytes < readCount {
            let writeCount = buffer.withUnsafeBytes { bytes -> Int in
              guard let baseAddress = bytes.baseAddress else {
                return -1
              }
              return Darwin.write(
                destinationDescriptor,
                baseAddress.advanced(by: writtenBytes),
                readCount - writtenBytes
              )
            }
            guard writeCount > 0 else {
              throw MLXLocalInferenceProviderError.invalidModelConfiguration
            }
            writtenBytes += writeCount
          }
          copiedBytes += UInt64(readCount)
        }
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600],
          ofItemAtPath: sourceArtifact.path
        )
      }
    )

    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try builder.makeSnapshot(for: configuration)
    }
  }

  @Test
  func rejectsNamespaceEnumerationBeyondItsBound() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let modelDirectory = root.appending(path: "model", directoryHint: .isDirectory)
    try makeCompleteModelDirectory(at: modelDirectory)
    let namespaceDirectory = root.appending(
      path: "snapshot-namespace",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: namespaceDirectory, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: namespaceDirectory.path
    )
    for name in ["claim-0", "snapshot-0", "claim-1", "snapshot-1", "unexpected"] {
      try Data().write(to: namespaceDirectory.appending(path: name))
    }
    let namespace = try MLXModelArtifactSnapshotNamespace(
      directory: namespaceDirectory,
      snapshotLimit: 2
    )

    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try MLXModelArtifactSnapshotBuilder(namespace: namespace).makeSnapshot(
        for: makeConfiguration(directory: modelDirectory)
      )
    }
  }

  @Test
  func rejectsExtraSnapshotEntriesBeforeUnboundedEnumeration() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let modelDirectory = root.appending(path: "model", directoryHint: .isDirectory)
    try makeCompleteModelDirectory(at: modelDirectory)
    let snapshot = try makeSnapshotBuilder(root: root, snapshotLimit: 1).makeSnapshot(
      for: makeConfiguration(directory: modelDirectory)
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: snapshot.directory.path
    )
    try Data().write(to: snapshot.directory.appending(path: "unexpected.json"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500],
      ofItemAtPath: snapshot.directory.path
    )

    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      try snapshot.validateBoundPath()
    }
  }

  @Test
  func defaultsToA16GBMacResourceEnvelope() throws {
    let policy = try MLXLocalModelResourcePolicy.macWith16GBMemory
    #expect(policy.maximumArtifactBytes == 6 * 1_024 * 1_024 * 1_024)
    #expect(policy.maximumContextTokens == 32_768)
    #expect(policy.maximumOutputTokens == 8_192)

    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try MLXLocalModelConfiguration(
        modelID: ModelID(rawValue: "model"),
        displayName: "Model",
        directory: root,
        contextWindow: policy.maximumContextTokens + 1,
        maximumOutputTokens: 128
      )
    }
    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try MLXLocalModelConfiguration(
        modelID: ModelID(rawValue: "model"),
        displayName: "Model",
        directory: root,
        maximumOutputTokens: policy.maximumOutputTokens + 1
      )
    }
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "hex-mlx-loader-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func makeConfiguration(
    directory: URL,
    resourcePolicy: MLXLocalModelResourcePolicy? = nil
  ) throws -> MLXLocalModelConfiguration {
    try MLXLocalModelConfiguration(
      modelID: ModelID(rawValue: "model"),
      displayName: "Model",
      directory: directory,
      maximumOutputTokens: 128,
      resourcePolicy: resourcePolicy
    )
  }

  private func makeCompleteModelDirectory(at directory: URL) throws {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false
    )
    try Data("{\"model_type\":\"test\"}".utf8).write(
      to: directory.appending(path: "config.json")
    )
    try Data("{}".utf8).write(to: directory.appending(path: "tokenizer.json"))
    try Data("weights".utf8).write(
      to: directory.appending(path: "model.safetensors")
    )
  }

  private func releaseSnapshotAfterReplacingPath(
    configuration: MLXLocalModelConfiguration,
    movedSnapshot: URL,
    replacement: SnapshotPathReplacement,
    builder: MLXModelArtifactSnapshotBuilder
  ) throws -> URL {
    let snapshot = try builder.makeSnapshot(for: configuration)
    let replacedPath = snapshot.directory
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: replacedPath.path
    )
    try FileManager.default.moveItem(at: replacedPath, to: movedSnapshot)
    switch replacement {
    case .directory(let sentinel):
      try FileManager.default.createDirectory(
        at: replacedPath,
        withIntermediateDirectories: false
      )
      try sentinel.write(to: replacedPath.appending(path: "sentinel"))
    case .file(let sentinel):
      try sentinel.write(to: replacedPath)
    }
    return replacedPath
  }

  private func makeSnapshotBuilder(
    root: URL,
    snapshotLimit: Int = MLXModelArtifactSnapshotNamespace.maximumSnapshotCount
  ) throws -> MLXModelArtifactSnapshotBuilder {
    try MLXModelArtifactSnapshotBuilder(
      namespace: MLXModelArtifactSnapshotNamespace(
        directory: root.appending(
          path: "snapshot-namespace",
          directoryHint: .isDirectory
        ),
        snapshotLimit: snapshotLimit
      )
    )
  }

  private func moveAndReleaseSnapshot(
    builder: MLXModelArtifactSnapshotBuilder,
    configuration: MLXLocalModelConfiguration,
    destination: URL
  ) throws -> URL {
    let snapshot = try builder.makeSnapshot(for: configuration)
    let directory = snapshot.directory
    try makeDirectoryWritable(directory)
    try FileManager.default.moveItem(at: directory, to: destination)
    return directory
  }

  private func exhaustSnapshotCapacity(
    builder: MLXModelArtifactSnapshotBuilder,
    configuration: MLXLocalModelConfiguration
  ) throws {
    let first = try builder.makeSnapshot(for: configuration)
    let second = try builder.makeSnapshot(for: configuration)
    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try builder.makeSnapshot(for: configuration)
    }
    withExtendedLifetime((first, second)) {}
  }

  private func makeNamespaceWritable(_ namespace: URL) throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: namespace.path)
    for name in names {
      try makeDirectoryWritable(namespace.appending(path: name, directoryHint: .isDirectory))
    }
  }

  private func makeDirectoryWritable(_ directory: URL) throws {
    guard FileManager.default.fileExists(atPath: directory.path) else {
      return
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directory.path
    )
  }

  private func fileSize(_ file: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    return try #require(attributes[.size] as? UInt64)
  }

  private actor LoadRecorder {
    private var directories: [URL] = []

    func record(_ directory: URL) {
      directories.append(directory)
    }

    func count() -> Int {
      directories.count
    }
  }

  private actor ReplacementLoadRecorder {
    private var loadedDirectory: URL?
    private var loadedConfiguration: Data?

    func record(directory: URL, observedConfiguration: Data) {
      loadedDirectory = directory
      loadedConfiguration = observedConfiguration
    }

    func directory() -> URL? {
      loadedDirectory
    }

    func observedConfiguration() -> Data? {
      loadedConfiguration
    }
  }

  private enum SnapshotPathReplacement {
    case directory(Data)
    case file(Data)
  }

  private enum StubError: Error {
    case invalidProcessProbeMode
    case processProbeTimedOut
    case unexpectedLoad
  }
}
