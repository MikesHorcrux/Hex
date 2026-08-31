import HexCore
import HexRuntime

actor ScriptedInferenceProvider: InferenceProvider {
  nonisolated let descriptor: ProviderDescriptor
  private let models: [ModelDescriptor]
  private var scripts: [InferenceScript]
  private var capturedRequests: [InferenceRequest] = []

  init(
    descriptor: ProviderDescriptor,
    models: [ModelDescriptor],
    scripts: [InferenceScript]
  ) {
    self.descriptor = descriptor
    self.models = models
    self.scripts = scripts
  }

  func availableModels() async throws -> [ModelDescriptor] {
    models
  }

  func stream(
    _ request: InferenceRequest
  ) async throws -> InferenceStream {
    capturedRequests.append(request)
    let script = scripts.isEmpty ? .streamFailure : scripts.removeFirst()
    switch script {
    case .events(let events):
      let stream = AsyncThrowingStream<InferenceStreamEvent, any Error> { continuation in
        for event in events {
          continuation.yield(event)
        }
        continuation.finish()
      }
      return InferenceStream(
        events: stream,
        onCancellation: {},
        waitForTermination: {}
      )
    case .openingFailure:
      throw ScriptedInferenceProviderError.provider
    case .streamFailure:
      let stream = AsyncThrowingStream<InferenceStreamEvent, any Error> { continuation in
        continuation.finish(throwing: ScriptedInferenceProviderError.provider)
      }
      return InferenceStream(
        events: stream,
        onCancellation: {},
        waitForTermination: {}
      )
    case .streamRuntimeFailure:
      let stream = AsyncThrowingStream<InferenceStreamEvent, any Error> { continuation in
        continuation.finish(
          throwing: AgentRuntimeError.invalidRequest("provider-owned private detail")
        )
      }
      return InferenceStream(
        events: stream,
        onCancellation: {},
        waitForTermination: {}
      )
    case .suspend:
      let stream = AsyncThrowingStream<InferenceStreamEvent, any Error> { _ in }
      return InferenceStream(
        events: stream,
        onCancellation: {},
        waitForTermination: {}
      )
    }
  }

  func requests() -> [InferenceRequest] {
    capturedRequests
  }
}
