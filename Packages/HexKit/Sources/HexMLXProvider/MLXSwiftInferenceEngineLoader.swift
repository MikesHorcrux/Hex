import HexProviders
import MLXLLM
import MLXLMCommon

public struct MLXSwiftInferenceEngineLoader: MLXInferenceEngineLoader, Sendable {
  public init() {}

  public func loadModel(
    _ configuration: MLXLocalModelConfiguration
  ) async throws -> any MLXInferenceEngine {
    try Task.checkCancellation()
    try validateDirectoryIdentity(configuration)
    let factory = LLMModelFactory(
      typeRegistry: LLMTypeRegistry.shared,
      modelRegistry: LLMRegistry()
    )
    let tokenizerLoader = MLXSwiftTokenizerLoader()
    let container = try await factory.loadContainer(
      from: configuration.directory,
      using: tokenizerLoader
    )
    try Task.checkCancellation()
    try validateDirectoryIdentity(configuration)
    return MLXSwiftInferenceEngine(
      model: container,
      modelID: configuration.modelID,
      defaultMaximumOutputTokens: configuration.maximumOutputTokens
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
