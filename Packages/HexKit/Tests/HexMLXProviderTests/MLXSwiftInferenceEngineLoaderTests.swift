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
      _ = try await MLXSwiftInferenceEngineLoader().loadModel(configuration)
    }
  }
}
