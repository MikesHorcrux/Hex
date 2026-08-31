public struct MLXInferenceEngineRun: Sendable {
  public let events: AsyncThrowingStream<MLXInferenceEngineEvent, any Error>
  private let cancellation: @Sendable () -> Void
  private let termination: @Sendable () async -> Void

  public init(
    events: AsyncThrowingStream<MLXInferenceEngineEvent, any Error>,
    cancel: @escaping @Sendable () -> Void,
    waitForTermination: @escaping @Sendable () async -> Void
  ) {
    self.events = events
    cancellation = cancel
    termination = waitForTermination
  }

  public func cancel() {
    cancellation()
  }

  /// Returns only after the physical engine producer has stopped touching model state.
  public func waitForTermination() async {
    await termination()
  }
}
