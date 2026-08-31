import Foundation

public struct OpenAIResponsesTransportResponse: Sendable {
  public let statusCode: Int
  public let contentType: String?
  public let body: AsyncThrowingStream<Data, any Error>

  public init(
    statusCode: Int,
    contentType: String? = "text/event-stream",
    body: AsyncThrowingStream<Data, any Error>
  ) {
    self.statusCode = statusCode
    self.contentType = contentType
    self.body = body
  }
}
