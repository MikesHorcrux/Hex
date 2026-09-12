/// A model-provider boundary. Implementations must propagate Swift task cancellation and
/// `CancellationError` without wrapping it. A normal stream emits exactly one `started` event and
/// one `completed` event. A throwing stream does not also emit `completed`. Implementations must
/// cancel and physically join owned inference work when their returned stream is abandoned.
public protocol InferenceProvider: Sendable {
  var descriptor: ProviderDescriptor { get }

  func availableModels() async throws -> [ModelDescriptor]

  func stream(
    _ request: InferenceRequest
  ) async throws -> InferenceStream
}
