import MLXLMCommon

struct MLXSwiftGenerationRun: Sendable {
  let events: AsyncStream<Generation>
  private let cancellation: @Sendable () -> Void
  private let termination: @Sendable () async -> Void

  init(
    events: AsyncStream<Generation>,
    cancel: @escaping @Sendable () -> Void,
    waitForTermination: @escaping @Sendable () async -> Void
  ) {
    self.events = events
    cancellation = cancel
    termination = waitForTermination
  }

  func cancel() {
    cancellation()
  }

  func waitForTermination() async {
    await termination()
  }
}
