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
  ) async throws -> AsyncThrowingStream<InferenceStreamEvent, any Error> {
    capturedRequests.append(request)
    let script = scripts.isEmpty ? .streamFailure : scripts.removeFirst()
    switch script {
    case .events(let events):
      return AsyncThrowingStream { continuation in
        for event in events {
          continuation.yield(event)
        }
        continuation.finish()
      }
    case .openingFailure:
      throw ScriptedInferenceProviderError.provider
    case .streamFailure:
      return AsyncThrowingStream { continuation in
        continuation.finish(throwing: ScriptedInferenceProviderError.provider)
      }
    case .streamRuntimeFailure:
      return AsyncThrowingStream { continuation in
        continuation.finish(
          throwing: AgentRuntimeError.invalidRequest("provider-owned private detail")
        )
      }
    case .suspend:
      return AsyncThrowingStream { _ in }
    }
  }

  func requests() -> [InferenceRequest] {
    capturedRequests
  }
}
