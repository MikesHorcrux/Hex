import Foundation

/// An owned transport response whose body producer has an explicit cancellation and join lifetime.
public final class OpenAIResponsesTransportResponse: Sendable {
  public let statusCode: Int
  public let contentType: String?
  public let body: AsyncThrowingStream<Data, any Error>
  private let cancellation: OpenAIResponsesTransportResponseCancellation
  private let termination: Task<Void, Never>

  public init(
    statusCode: Int,
    contentType: String? = "text/event-stream",
    body: AsyncThrowingStream<Data, any Error>,
    cancel: @escaping @Sendable () -> Void,
    waitForTermination: @escaping @Sendable () async -> Void
  ) {
    self.statusCode = statusCode
    self.contentType = contentType
    self.body = body
    cancellation = OpenAIResponsesTransportResponseCancellation(action: cancel)
    termination = Task {
      await waitForTermination()
    }
  }

  deinit {
    cancellation.cancel()
  }

  public func cancel() {
    cancellation.cancel()
  }

  public func waitForTermination() async {
    await termination.value
  }

  public func cancelAndWait() async {
    cancellation.cancel()
    await termination.value
  }
}
