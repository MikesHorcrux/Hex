import Foundation
import HexProviders
import MLXLLM
import MLXLMCommon

public struct MLXSwiftInferenceEngineLoader: MLXInferenceEngineLoader, Sendable {
  private let loadContainer: @Sendable (URL) async throws -> ModelContainer
  private let snapshotBuilder: MLXModelArtifactSnapshotBuilder

  public init(
    loadContainer: @escaping @Sendable (URL) async throws -> ModelContainer
  ) {
    self.loadContainer = loadContainer
    snapshotBuilder = MLXModelArtifactSnapshotBuilder()
  }

  init(
    loadContainer: @escaping @Sendable (URL) async throws -> ModelContainer,
    snapshotBuilder: MLXModelArtifactSnapshotBuilder
  ) {
    self.loadContainer = loadContainer
    self.snapshotBuilder = snapshotBuilder
  }

  public init(factory: LLMModelFactory) {
    loadContainer = { directory in
      try await factory.loadContainer(
        from: directory,
        using: MLXSwiftTokenizerLoader()
      )
    }
    snapshotBuilder = MLXModelArtifactSnapshotBuilder()
  }

  public func loadModel(
    _ configuration: MLXLocalModelConfiguration
  ) async throws -> any MLXInferenceEngine {
    try Task.checkCancellation()
    try validateDirectoryIdentity(configuration)
    let snapshot = try snapshotBuilder.makeSnapshot(for: configuration)
    try Task.checkCancellation()
    try snapshot.validateBoundPath()
    let container: ModelContainer
    do {
      container = try await loadContainer(snapshot.directory)
    } catch {
      do {
        try snapshot.validateBoundPath()
      } catch {
        throw MLXLocalInferenceProviderError.invalidModelConfiguration
      }
      throw error
    }
    try snapshot.validateBoundPath()
    try Task.checkCancellation()
    return MLXSwiftInferenceEngine(
      model: container,
      modelID: configuration.modelID,
      defaultMaximumOutputTokens: configuration.maximumOutputTokens,
      maximumContextTokens:
        configuration.contextWindow ?? configuration.resourcePolicy.maximumContextTokens,
      supportsToolCalling: configuration.supportsToolCalling,
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
