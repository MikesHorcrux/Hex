import Foundation
import HexProviders
import MLXLLM
import MLXLMCommon

public struct MLXSwiftInferenceEngineLoader: MLXInferenceEngineLoader, Sendable {
  private let loadContainer: @Sendable (URL) async throws -> ModelContainer

  public init(
    loadContainer: @escaping @Sendable (URL) async throws -> ModelContainer
  ) {
    self.loadContainer = loadContainer
  }

  public init(factory: LLMModelFactory) {
    loadContainer = { directory in
      try await factory.loadContainer(
        from: directory,
        using: MLXSwiftTokenizerLoader()
      )
    }
  }

  public func loadModel(
    _ configuration: MLXLocalModelConfiguration
  ) async throws -> any MLXInferenceEngine {
    try Task.checkCancellation()
    try validateDirectoryIdentity(configuration)
    let snapshot = try MLXModelArtifactSnapshotBuilder().makeSnapshot(for: configuration)
    try Task.checkCancellation()
    let container = try await loadContainer(snapshot.directory)
    try Task.checkCancellation()
    return MLXSwiftInferenceEngine(
      model: container,
      modelID: configuration.modelID,
      defaultMaximumOutputTokens: configuration.maximumOutputTokens,
      artifactSnapshot: snapshot
    )
  }

  private func validateDirectoryIdentity(
    _ configuration: MLXLocalModelConfiguration
  ) throws {
    guard configuration.hasOriginalDirectoryIdentity() else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
  }
}
