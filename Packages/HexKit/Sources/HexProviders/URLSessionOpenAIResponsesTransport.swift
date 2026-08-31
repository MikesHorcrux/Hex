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
      try Task.checkCancellation()

      guard let httpResponse = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
      }

      let body = AsyncThrowingStream<Data, any Error>(bufferingPolicy: .bufferingOldest(16)) {
        continuation in
        let producer = Task {
          do {
            var chunk = Data()
            chunk.reserveCapacity(8 * 1_024)

            for try await byte in bytes {
              try Task.checkCancellation()
              chunk.append(byte)
              if chunk.count == 8 * 1_024 {
                try Self.yield(chunk, to: continuation)
                chunk.removeAll(keepingCapacity: true)
              }
            }

            if !chunk.isEmpty {
              try Self.yield(chunk, to: continuation)
            }
            continuation.finish()
          } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
          } catch {
            if Task.isCancelled {
              continuation.finish(throwing: CancellationError())
            } else {
              continuation.finish(throwing: error)
            }
          }
        }

        continuation.onTermination = { @Sendable _ in
          producer.cancel()
        }
      }

      return OpenAIResponsesTransportResponse(
        statusCode: httpResponse.statusCode,
        contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
        body: body
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

  private static func yield(
    _ data: Data,
    to continuation: AsyncThrowingStream<Data, any Error>.Continuation
  ) throws {
    switch continuation.yield(data) {
    case .enqueued:
      return
    case .dropped:
      throw URLError(.dataLengthExceedsMaximum)
    case .terminated:
      throw CancellationError()
    @unknown default:
      throw URLError(.unknown)
    }
  }
}
