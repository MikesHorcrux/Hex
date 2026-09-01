import HexCore

struct GatewayTestInferenceProvider: InferenceProvider, Sendable {
  let modelID = ModelID(rawValue: "gateway-test-model")
  let descriptor = ProviderDescriptor(
    id: ProviderID(rawValue: "gateway-test-provider"),
    displayName: "Gateway Test Provider",
    capabilities: [.textInput, .streaming]
  )

  func availableModels() async throws -> [ModelDescriptor] {
    try Task.checkCancellation()
    return [
      ModelDescriptor(
        id: modelID,
        providerID: descriptor.id,
        displayName: "Gateway Test Model",
        capabilities: [.textInput, .streaming],
        maxOutputTokens: 256
      )
    ]
  }

  func stream(
    _ request: InferenceRequest
  ) async throws -> InferenceStream {
    _ = request
    try Task.checkCancellation()
    let events = AsyncThrowingStream<InferenceStreamEvent, any Error> { continuation in
      continuation.yield(.started(providerResponseID: "gateway-test-response"))
      continuation.yield(.textDelta("done"))
      continuation.yield(.completed(.stop))
      continuation.finish()
    }
    return InferenceStream(
      events: events,
      onCancellation: {},
      waitForTermination: {}
    )
  }
}
