import Foundation
import HexCore
import HexProviders
import Testing

@testable import HexMLXProvider

@Suite("MLX local inference provider builder")
struct MLXLocalInferenceProviderBuilderTests {
  @Test
  func mapsSettingsToValidatedProviderConfigurationWithoutLoading() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = try HexMLXBackendSettings(
      modelID: "mlx-model",
      displayName: "Local model",
      directory: directory,
      contextWindow: 4_096,
      maximumOutputTokens: 2_048,
      supportsToolCalling: true,
      supportsParallelToolCalling: true
    )
    let loader = RecordingLoader()
    let builder = MLXLocalInferenceProviderBuilder(engineLoader: loader)

    let configuration = try builder.configuration(for: settings)
    let model = try #require(configuration.models.first)
    #expect(configuration.providerID == MLXLocalInferenceProviderBuilder.defaultProviderID)
    #expect(
      configuration.displayName
        == MLXLocalInferenceProviderBuilder.defaultProviderDisplayName
    )
    #expect(configuration.maximumBufferedEvents == 64)
    #expect(model.modelID == ModelID(rawValue: "mlx-model"))
    #expect(model.displayName == "Local model")
    #expect(model.directory == directory.standardizedFileURL.resolvingSymlinksInPath())
    #expect(model.contextWindow == 4_096)
    #expect(model.maximumOutputTokens == 2_048)
    #expect(model.supportsToolCalling)
    #expect(model.supportsParallelToolCalling)
    #expect(
      model.capabilities == [
        .textInput,
        .streaming,
        .toolCalling,
        .parallelToolCalling,
      ])
    #expect(model.resourcePolicy.maximumContextTokens == 32_768)
    #expect(model.resourcePolicy.maximumOutputTokens == 8_192)

    let provider = try builder.makeProvider(for: settings)
    #expect(provider.descriptor.id == MLXLocalInferenceProviderBuilder.defaultProviderID)
    #expect(provider.descriptor.displayName == "Local MLX")
    #expect(await loader.loadCount() == 0)
    #expect((try await provider.availableModels()).first?.id == ModelID(rawValue: "mlx-model"))
    #expect(await loader.loadCount() == 0)
  }

  @Test
  func rejectsUnconfiguredOrMissingModelDirectoriesBeforeProviderConstruction() throws {
    let builder = MLXLocalInferenceProviderBuilder(
      makeEngineLoader: { RecordingLoader() }
    )

    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try builder.configuration(for: HexMLXBackendSettings())
    }

    let missingDirectory = URL(
      fileURLWithPath: "/tmp/hex-mlx-builder-missing-\(UUID().uuidString)"
    )
    let settings = try HexMLXBackendSettings(
      modelID: "mlx-model",
      displayName: "Local model",
      directory: missingDirectory,
      maximumOutputTokens: 2_048
    )
    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try builder.configuration(for: settings)
    }
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "hex-mlx-builder-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false
    )
    return directory
  }

  private actor RecordingLoader: MLXInferenceEngineLoader {
    private var count = 0

    func loadModel(
      _ configuration: MLXLocalModelConfiguration
    ) async throws -> any MLXInferenceEngine {
      count += 1
      throw MLXLocalInferenceProviderError.modelLoadFailed
    }

    func loadCount() -> Int {
      count
    }
  }
}
