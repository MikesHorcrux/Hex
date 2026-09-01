import HexCore

struct GatewayTestInferenceProvider: InferenceProvider, Sendable {
  let modelID = ModelID(rawValue: "gateway-test-model")
  let toolCall: ToolCall?
  let descriptor = ProviderDescriptor(
    id: ProviderID(rawValue: "gateway-test-provider"),
    displayName: "Gateway Test Provider",
    capabilities: [.textInput, .streaming, .toolCalling]
  )

  init(toolCall: ToolCall? = nil) {
    self.toolCall = toolCall
  }

  func availableModels() async throws -> [ModelDescriptor] {
    try Task.checkCancellation()
    return [
      ModelDescriptor(
        id: modelID,
        providerID: descriptor.id,
        displayName: "Gateway Test Model",
        capabilities: [.textInput, .streaming, .toolCalling],
        maxOutputTokens: 256
      )
    ]
  }

  func stream(
    _ request: InferenceRequest
  ) async throws -> InferenceStream {
    try Task.checkCancellation()
    let hasToolResult = request.messages.contains { message in
      message.role == .tool
    }
    let events = AsyncThrowingStream<InferenceStreamEvent, any Error> { continuation in
      continuation.yield(.started(providerResponseID: "gateway-test-response"))
      if let toolCall, !hasToolResult {
        continuation.yield(.toolCall(toolCall))
        continuation.yield(.completed(.toolCalls))
      } else {
        continuation.yield(.textDelta("done"))
        continuation.yield(.completed(.stop))
      }
      continuation.finish()
    }
    return InferenceStream(
      events: events,
      onCancellation: {},
      waitForTermination: {}
    )
  }
}
