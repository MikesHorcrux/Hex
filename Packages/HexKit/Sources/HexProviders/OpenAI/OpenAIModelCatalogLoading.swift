import HexCore

/// An authenticated model discovery boundary; model access remains enforced by the provider.
public protocol OpenAIModelCatalogLoading: Sendable {
  func availableModels() async throws -> [ModelDescriptor]
}
