import Foundation

public final class URLSessionOpenAIResponsesTransport: OpenAIResponsesTransport, Sendable {
  private let session: URLSession
  private let sessionDelegate: OpenAINoRedirectURLSessionDelegate

  public init() {
    let sessionDelegate = OpenAINoRedirectURLSessionDelegate()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.urlCache = nil
    configuration.waitsForConnectivity = false
    self.sessionDelegate = sessionDelegate
    self.session = URLSession(
      configuration: configuration,
      delegate: sessionDelegate,
      delegateQueue: nil
    )
  }

  public func send(_ request: URLRequest) async throws -> OpenAIResponsesTransportResponse {
    do {
      let (bytes, response) = try await session.bytes(for: request)
      let networkTask = bytes.task
      if Task.isCancelled {
        networkTask.cancel()
        throw CancellationError()
      }

      guard let httpResponse = response as? HTTPURLResponse else {
        networkTask.cancel()
        throw URLError(.badServerResponse)
      }

      let (body, producer) = OpenAIResponsesBodyStreamer.start(bytes)

      return OpenAIResponsesTransportResponse(
        statusCode: httpResponse.statusCode,
        contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
        body: body,
        cancel: {
          producer.cancel()
          networkTask.cancel()
        },
        waitForTermination: {
          await producer.value
          networkTask.cancel()
        }
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if Task.isCancelled {
        throw CancellationError()
      }
      throw error
    }
  }

}
