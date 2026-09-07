import Foundation
import HexCore

actor URLSessionMCPHTTPTransport: MCPHTTPTransport {
  private let session: URLSession

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.urlCache = nil
    configuration.waitsForConnectivity = false
    session = URLSession(
      configuration: configuration,
      delegate: MCPHTTPRedirectRejectingDelegate(),
      delegateQueue: nil
    )
  }

  func send(
    _ request: URLRequest,
    maximumResponseBytes: Int
  ) async throws -> MCPHTTPResponse {
    try await sendResponse(
      request, maximumResponseBytes: maximumResponseBytes,
      maximumSSEEvents: 1, receiveSSEMessage: nil)
  }

  func send(
    _ request: URLRequest,
    maximumResponseBytes: Int,
    maximumSSEEvents: Int,
    receiveSSEMessage: @escaping @Sendable (JSONValue, [String: String]) async throws -> Bool
  ) async throws -> MCPHTTPResponse {
    try await sendResponse(
      request, maximumResponseBytes: maximumResponseBytes,
      maximumSSEEvents: maximumSSEEvents, receiveSSEMessage: receiveSSEMessage)
  }

  private func sendResponse(
    _ request: URLRequest,
    maximumResponseBytes: Int,
    maximumSSEEvents: Int,
    receiveSSEMessage: (@Sendable (JSONValue, [String: String]) async throws -> Bool)?
  ) async throws -> MCPHTTPResponse {
    try Task.checkCancellation()
    guard request.timeoutInterval.isFinite, request.timeoutInterval > 0 else {
      throw MCPClientSessionError.limitExceeded
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(request.timeoutInterval))
    let operation = Task {
      try await self.receiveResponse(
        request, maximumResponseBytes: maximumResponseBytes,
        maximumSSEEvents: maximumSSEEvents, receiveSSEMessage: receiveSSEMessage)
    }
    let timeout = Task {
      do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
      operation.cancel()
    }
    defer { timeout.cancel() }
    do {
      return try await withTaskCancellationHandler {
        try await operation.value
      } onCancel: {
        operation.cancel()
      }
    } catch {
      if !Task.isCancelled, ContinuousClock.now >= deadline {
        throw MCPClientSessionError.requestTimedOut
      }
      throw error
    }
  }

  private func receiveResponse(
    _ request: URLRequest,
    maximumResponseBytes: Int,
    maximumSSEEvents: Int,
    receiveSSEMessage: (@Sendable (JSONValue, [String: String]) async throws -> Bool)?
  ) async throws -> MCPHTTPResponse {
    try Task.checkCancellation()
    guard maximumResponseBytes > 0 else {
      throw MCPClientSessionError.limitExceeded
    }
    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
    do {
      (bytes, response) = try await session.bytes(for: request)
    } catch { throw Self.transportError(error) }
    // Returning a terminal SSE event or rejecting an oversized response must release the request.
    defer { bytes.task.cancel() }
    guard
      let httpResponse = response as? HTTPURLResponse,
      let finalURL = httpResponse.url,
      finalURL == request.url
    else {
      throw MCPClientSessionError.protocolViolation
    }
    if response.expectedContentLength > Int64(maximumResponseBytes) {
      throw MCPClientSessionError.limitExceeded
    }

    let headers = try Self.headers(from: httpResponse)
    let responseMetadata = MCPHTTPResponse(
      statusCode: httpResponse.statusCode, headers: headers, body: Data(), finalURL: finalURL)
    let streamsMessages = responseMetadata.statusCode == 200 && responseMetadata.isEventStream
    let declaredLength = Self.completeBodyLength(headers: headers)
    var framer = MCPSSEEventFramer()
    var eventCount = 0

    var body = Data()
    body.reserveCapacity(
      max(0, min(Int(response.expectedContentLength), maximumResponseBytes))
    )
    if declaredLength == 0 { return responseMetadata }
    do {
      for try await byte in bytes {
        guard body.count < maximumResponseBytes else {
          throw MCPClientSessionError.limitExceeded
        }
        body.append(byte)
        if streamsMessages, let receiveSSEMessage, let event = framer.append(byte) {
          let messages = try MCPSSEMessageDecoder.decode(
            event, maximumEvents: 1, maximumMessageBytes: maximumResponseBytes)
          eventCount += messages.count
          guard eventCount <= maximumSSEEvents else { throw MCPClientSessionError.limitExceeded }
          for message in messages {
            if try await receiveSSEMessage(message, headers) {
              return MCPHTTPResponse(
                statusCode: httpResponse.statusCode, headers: headers, body: body,
                finalURL: finalURL)
            }
          }
        }
        // The declared unencoded HTTP body is complete before the next suspended read. Retain
        // it through cancellation; an unknown-length or encoded prefix is never sufficient.
        if !streamsMessages, declaredLength == body.count {
          return MCPHTTPResponse(
            statusCode: httpResponse.statusCode, headers: headers, body: body, finalURL: finalURL)
        }
        try Task.checkCancellation()
      }
      if streamsMessages, let receiveSSEMessage, let event = framer.finish() {
        let messages = try MCPSSEMessageDecoder.decode(
          event, maximumEvents: 1, maximumMessageBytes: maximumResponseBytes)
        eventCount += messages.count
        guard eventCount <= maximumSSEEvents else { throw MCPClientSessionError.limitExceeded }
        for message in messages { _ = try await receiveSSEMessage(message, headers) }
      }
    } catch let error as MCPClientSessionError {
      throw error
    } catch { throw Self.transportError(error) }

    return MCPHTTPResponse(
      statusCode: httpResponse.statusCode,
      headers: headers,
      body: body,
      finalURL: finalURL
    )
  }

  private static func headers(from httpResponse: HTTPURLResponse) throws -> [String: String] {
    var headers: [String: String] = [:]
    for (rawName, rawValue) in httpResponse.allHeaderFields {
      guard let name = rawName as? String, let value = rawValue as? String else {
        continue
      }
      let normalizedName = name.lowercased()
      guard headers[normalizedName] == nil else {
        throw MCPClientSessionError.protocolViolation
      }
      headers[normalizedName] = value
    }
    return headers
  }

  private static func completeBodyLength(headers: [String: String]) -> Int? {
    guard headers["transfer-encoding"] == nil,
      headers["content-encoding"] == nil || headers["content-encoding"]?.lowercased() == "identity",
      let rawLength = headers["content-length"], !rawLength.isEmpty,
      rawLength.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(rawLength)
    else { return nil }
    return length
  }

  private static func transportError(_ error: any Error) -> any Error {
    if error is CancellationError || Task.isCancelled { return CancellationError() }
    if (error as? URLError)?.code == .timedOut { return MCPClientSessionError.requestTimedOut }
    return MCPClientSessionError.connectionClosed
  }
}
