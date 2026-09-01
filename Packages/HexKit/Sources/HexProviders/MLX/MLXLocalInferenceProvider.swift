import HexCore

public actor MLXLocalInferenceProvider: InferenceProvider {
  public nonisolated let descriptor: ProviderDescriptor
  let configuration: MLXLocalProviderConfiguration
  let engineLoader: any MLXInferenceEngineLoader
  var activeRequestID: InferenceRequestID?
  var cachedModelID: ModelID?
  var cachedEngine: (any MLXInferenceEngine)?

  public init(
    configuration: MLXLocalProviderConfiguration,
    engineLoader: any MLXInferenceEngineLoader
  ) {
    var capabilities = Set<InferenceCapability>()
    if let firstModel = configuration.models.first {
      capabilities = firstModel.capabilities
      for model in configuration.models.dropFirst() {
        capabilities.formIntersection(model.capabilities)
      }
    }
    descriptor = ProviderDescriptor(
      id: configuration.providerID,
      displayName: configuration.displayName,
      capabilities: capabilities
    )
    self.configuration = configuration
    self.engineLoader = engineLoader
  }

  public func availableModels() async throws -> [ModelDescriptor] {
    try Task.checkCancellation()
    return configuration.models.map { model in
      ModelDescriptor(
        id: model.modelID,
        providerID: configuration.providerID,
        displayName: model.displayName,
        capabilities: model.capabilities,
        contextWindow: model.contextWindow,
        maxOutputTokens: model.maximumOutputTokens
      )
    }
  }
}
