import Foundation

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
    try Task.checkCancellation()
    guard maximumResponseBytes > 0 else {
      throw MCPClientSessionError.limitExceeded
    }
    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
    do {
      (bytes, response) = try await session.bytes(for: request)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw MCPClientSessionError.connectionClosed
    }
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

    var body = Data()
    body.reserveCapacity(
      max(0, min(Int(response.expectedContentLength), maximumResponseBytes))
    )
    do {
      for try await byte in bytes {
        try Task.checkCancellation()
        guard body.count < maximumResponseBytes else {
          throw MCPClientSessionError.limitExceeded
        }
        body.append(byte)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as MCPClientSessionError {
      throw error
    } catch {
      throw MCPClientSessionError.connectionClosed
    }

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
    return MCPHTTPResponse(
      statusCode: httpResponse.statusCode,
      headers: headers,
      body: body,
      finalURL: finalURL
    )
  }
}
