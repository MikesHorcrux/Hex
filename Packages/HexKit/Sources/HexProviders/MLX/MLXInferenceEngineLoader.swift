public protocol MLXInferenceEngineLoader: Sendable {
  func loadModel(
    _ configuration: MLXLocalModelConfiguration
  ) async throws -> any MLXInferenceEngine
}
