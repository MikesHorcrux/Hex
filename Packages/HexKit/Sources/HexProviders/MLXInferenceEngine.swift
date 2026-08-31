import HexCore

public protocol MLXInferenceEngine: Sendable {
  func stream(
    _ request: InferenceRequest
  ) async throws -> AsyncThrowingStream<MLXInferenceEngineEvent, any Error>
}
