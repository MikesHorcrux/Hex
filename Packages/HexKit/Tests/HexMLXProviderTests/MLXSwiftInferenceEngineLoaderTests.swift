import Foundation
import HexCore
import HexProviders
import Testing

@testable import HexMLXProvider

@Suite("MLX Swift inference engine loader")
struct MLXSwiftInferenceEngineLoaderTests {
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

    let snapshot = try MLXModelArtifactSnapshotBuilder().makeSnapshot(for: configuration)
    try Data("mutated".utf8).write(to: modelDirectory.appending(path: "config.json"))

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

  private actor LoadRecorder {
    private var directories: [URL] = []

    func record(_ directory: URL) {
      directories.append(directory)
    }

    func count() -> Int {
      directories.count
    }
  }

  private enum StubError: Error {
    case unexpectedLoad
  }
}
