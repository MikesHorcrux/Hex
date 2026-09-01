@preconcurrency import Foundation

public actor URLSessionWebFetcher: WebFetching {
  private let addressValidator: any WebAddressValidating
  private let session: URLSession

  public init(addressValidator: any WebAddressValidating) {
    self.addressValidator = addressValidator
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.httpMaximumConnectionsPerHost = 2
    configuration.waitsForConnectivity = false
    session = URLSession(configuration: configuration)
  }

  public func fetch(_ request: WebFetchRequest) async throws -> WebFetchResponse {
    do {
      try Task.checkCancellation()
      guard
        (1...1_048_576).contains(request.maximumResponseBytes),
        (1...60).contains(request.timeoutSeconds),
        request.body?.count ?? 0 <= 16_384,
        request.method == .post || request.body == nil,
        request.body == nil || request.contentType != nil
      else {
        throw WebToolError.invalidArguments
      }
      let url = try WebURLPolicy.validatedURL(request.url)
      try await addressValidator.validate(url)

      var urlRequest = URLRequest(
        url: url,
        cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
        timeoutInterval: TimeInterval(request.timeoutSeconds)
      )
      urlRequest.httpMethod = request.method.rawValue
      urlRequest.httpBody = request.body
      urlRequest.setValue(
        "text/html, text/plain, application/json, application/xml;q=0.9",
        forHTTPHeaderField: "Accept")
      urlRequest.setValue("Hex/0.1 (local personal agent)", forHTTPHeaderField: "User-Agent")
      if let contentType = request.contentType {
        urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
      }

      let delegate = WebRedirectRejectingDelegate()
      let (bytes, response) = try await session.bytes(for: urlRequest, delegate: delegate)
      guard let response = response as? HTTPURLResponse, let responseURL = response.url else {
        throw WebToolError.invalidResponse
      }
      guard try WebURLPolicy.validatedURL(responseURL) == url else {
        throw WebToolError.invalidResponse
      }

      var body = Data()
      body.reserveCapacity(
        min(max(Int(response.expectedContentLength), 0), request.maximumResponseBytes)
      )
      var isTruncated = false
      for try await byte in bytes {
        if body.count == request.maximumResponseBytes {
          isTruncated = true
          bytes.task.cancel()
          break
        }
        body.append(byte)
      }
      try Task.checkCancellation()

      let redirectURL = try validatedRedirectURL(
        response.value(forHTTPHeaderField: "Location"),
        relativeTo: url
      )
      return WebFetchResponse(
        url: url,
        statusCode: response.statusCode,
        contentType: response.value(forHTTPHeaderField: "Content-Type"),
        body: body,
        isTruncated: isTruncated,
        redirectURL: redirectURL
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as WebToolError {
      throw error
    } catch {
      throw WebToolError.networkFailure
    }
  }

  private func validatedRedirectURL(
    _ location: String?,
    relativeTo baseURL: URL
  ) throws -> URL? {
    guard let location else { return nil }
    guard let resolved = URL(string: location, relativeTo: baseURL)?.absoluteURL else {
      throw WebToolError.invalidResponse
    }
    return try WebURLPolicy.validatedURL(resolved)
  }
}
