import HexCore

public protocol MLXInferenceEngine: Sendable {
  /// Starts one physical generation. The returned run must retain ownership of all underlying
  /// generation work until `waitForTermination()` returns.
  func start(
    _ request: InferenceRequest
  ) async throws -> MLXInferenceEngineRun
}
