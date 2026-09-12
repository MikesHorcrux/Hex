import HexCore

struct HexGatewayInertInferenceProvider: InferenceProvider, Sendable {
  let descriptor = ProviderDescriptor(
    id: ProviderID(rawValue: "inert"),
    displayName: "No inference provider",
    capabilities: []
  )

  func availableModels() async throws -> [ModelDescriptor] {
    try Task.checkCancellation()
    return []
  }

  func stream(
    _ request: InferenceRequest
  ) async throws -> InferenceStream {
    _ = request
    try Task.checkCancellation()
    throw HexGatewayCompositionError.inferenceUnavailable
  }
}
