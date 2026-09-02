import Foundation

/// Direct, dependency-free implementation of the OAuth flow used by current Codex harnesses.
public final class URLSessionChatGPTCodexOAuthTransport: ChatGPTCodexOAuthTransport, Sendable {
  private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
  private static let issuer = "https://auth.openai.com"
  private static let maximumResponseBytes = 64 * 1_024

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
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 30
    self.sessionDelegate = sessionDelegate
    session = URLSession(
      configuration: configuration,
      delegate: sessionDelegate,
      delegateQueue: nil
    )
  }

  public func requestDeviceAuthorization() async throws
    -> ChatGPTCodexDeviceAuthorizationChallenge
  {
    let endpoint = try Self.endpoint(path: "/api/accounts/deviceauth/usercode")
    var request = Self.request(url: endpoint, contentType: "application/json")
    request.httpBody = try JSONSerialization.data(
      withJSONObject: ["client_id": Self.clientID],
      options: [.sortedKeys]
    )
    let response = try await send(request)
    guard response.statusCode != 429 else { throw ChatGPTCodexOAuthError.rateLimited }
    guard response.statusCode == 200 else { throw ChatGPTCodexOAuthError.transportFailed }
    let decoded: DeviceAuthorizationResponse = try Self.decode(response.data)
    let interval = TimeInterval(max(3, min(decoded.interval ?? 5, 30)))
    guard
      Self.isValidOpaqueValue(decoded.userCode, maximumBytes: 128),
      Self.isValidOpaqueValue(decoded.deviceAuthorizationID, maximumBytes: 2_048),
      let verificationURL = URL(string: "\(Self.issuer)/codex/device")
    else {
      throw ChatGPTCodexOAuthError.transportFailed
    }
    return ChatGPTCodexDeviceAuthorizationChallenge(
      userCode: decoded.userCode,
      verificationURL: verificationURL,
      deviceAuthorizationID: decoded.deviceAuthorizationID,
      pollInterval: interval,
      expiresAt: Date().addingTimeInterval(15 * 60)
    )
  }

  public func pollDeviceAuthorization(
    deviceAuthorizationID: String,
    userCode: String
  ) async throws -> ChatGPTCodexOAuthPollResult {
    guard
      Self.isValidOpaqueValue(deviceAuthorizationID, maximumBytes: 2_048),
      Self.isValidOpaqueValue(userCode, maximumBytes: 128)
    else {
      throw ChatGPTCodexOAuthError.authorizationRejected
    }
    let endpoint = try Self.endpoint(path: "/api/accounts/deviceauth/token")
    var request = Self.request(url: endpoint, contentType: "application/json")
    request.httpBody = try JSONSerialization.data(
      withJSONObject: [
        "device_auth_id": deviceAuthorizationID,
        "user_code": userCode,
      ],
      options: [.sortedKeys]
    )
    let response = try await send(request)
    if response.statusCode == 403 || response.statusCode == 404 {
      return .pending
    }
    guard response.statusCode != 429 else { throw ChatGPTCodexOAuthError.rateLimited }
    guard response.statusCode == 200 else { throw ChatGPTCodexOAuthError.authorizationRejected }
    let decoded: PollResponse = try Self.decode(response.data)
    guard
      Self.isValidOpaqueValue(decoded.authorizationCode, maximumBytes: 8 * 1_024),
      Self.isValidOpaqueValue(decoded.codeVerifier, maximumBytes: 2_048)
    else {
      throw ChatGPTCodexOAuthError.authorizationRejected
    }
    return .authorized(
      authorizationCode: decoded.authorizationCode,
      codeVerifier: decoded.codeVerifier
    )
  }

  public func exchangeAuthorizationCode(
    _ authorizationCode: String,
    codeVerifier: String
  ) async throws -> ChatGPTCodexOAuthTokenResponse {
    guard
      Self.isValidOpaqueValue(authorizationCode, maximumBytes: 8 * 1_024),
      Self.isValidOpaqueValue(codeVerifier, maximumBytes: 2_048)
    else {
      throw ChatGPTCodexOAuthError.tokenExchangeFailed
    }
    let endpoint = try Self.endpoint(path: "/oauth/token")
    var request = Self.request(
      url: endpoint,
      contentType: "application/x-www-form-urlencoded"
    )
    request.httpBody = try Self.formBody([
      "grant_type": "authorization_code",
      "code": authorizationCode,
      "redirect_uri": "\(Self.issuer)/deviceauth/callback",
      "client_id": Self.clientID,
      "code_verifier": codeVerifier,
    ])
    return try await tokenResponse(for: request, refresh: false)
  }

  public func refresh(_ refreshToken: String) async throws -> ChatGPTCodexOAuthTokenResponse {
    guard Self.isValidOpaqueValue(refreshToken, maximumBytes: 32 * 1_024) else {
      throw ChatGPTCodexOAuthError.refreshRejected
    }
    let endpoint = try Self.endpoint(path: "/oauth/token")
    var request = Self.request(
      url: endpoint,
      contentType: "application/x-www-form-urlencoded"
    )
    request.httpBody = try Self.formBody([
      "grant_type": "refresh_token",
      "refresh_token": refreshToken,
      "client_id": Self.clientID,
    ])
    return try await tokenResponse(for: request, refresh: true)
  }

  private func tokenResponse(
    for request: URLRequest,
    refresh: Bool
  ) async throws -> ChatGPTCodexOAuthTokenResponse {
    let response = try await send(request)
    guard response.statusCode != 429 else { throw ChatGPTCodexOAuthError.rateLimited }
    guard response.statusCode == 200 else {
      throw refresh
        ? ChatGPTCodexOAuthError.refreshRejected
        : ChatGPTCodexOAuthError.tokenExchangeFailed
    }
    let decoded: TokenResponse = try Self.decode(response.data)
    guard Self.isValidOpaqueValue(decoded.accessToken, maximumBytes: 32 * 1_024) else {
      throw refresh
        ? ChatGPTCodexOAuthError.refreshRejected
        : ChatGPTCodexOAuthError.tokenExchangeFailed
    }
    if let refreshToken = decoded.refreshToken,
      !Self.isValidOpaqueValue(refreshToken, maximumBytes: 32 * 1_024)
    {
      throw ChatGPTCodexOAuthError.invalidCredentials
    }
    return ChatGPTCodexOAuthTokenResponse(
      accessToken: decoded.accessToken,
      refreshToken: decoded.refreshToken,
      idToken: decoded.idToken,
      expiresIn: decoded.expiresIn
    )
  }

  private func send(_ request: URLRequest) async throws -> HTTPResult {
    do {
      let (data, response) = try await session.data(for: request)
      try Task.checkCancellation()
      guard
        data.count <= Self.maximumResponseBytes,
        let response = response as? HTTPURLResponse,
        response.url?.scheme == "https",
        response.url?.host?.lowercased() == "auth.openai.com"
      else {
        throw ChatGPTCodexOAuthError.transportFailed
      }
      return HTTPResult(statusCode: response.statusCode, data: data)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ChatGPTCodexOAuthError {
      throw error
    } catch {
      throw ChatGPTCodexOAuthError.transportFailed
    }
  }

  private static func endpoint(path: String) throws -> URL {
    guard let url = URL(string: issuer + path) else {
      throw ChatGPTCodexOAuthError.transportFailed
    }
    return url
  }

  private static func request(url: URL, contentType: String) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Hex/1.0", forHTTPHeaderField: "User-Agent")
    request.setValue("hex", forHTTPHeaderField: "originator")
    return request
  }

  private static func formBody(_ values: [String: String]) throws -> Data {
    var components = URLComponents()
    components.queryItems = values.sorted(by: { $0.key < $1.key }).map {
      URLQueryItem(name: $0.key, value: $0.value)
    }
    guard let query = components.percentEncodedQuery, let data = query.data(using: .utf8) else {
      throw ChatGPTCodexOAuthError.transportFailed
    }
    return data
  }

  private static func decode<Value: Decodable>(_ data: Data) throws -> Value {
    do {
      return try JSONDecoder().decode(Value.self, from: data)
    } catch {
      throw ChatGPTCodexOAuthError.transportFailed
    }
  }

  private static func isValidOpaqueValue(_ value: String, maximumBytes: Int) -> Bool {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= maximumBytes else { return false }
    return bytes.allSatisfy { (0x21...0x7E).contains($0) }
  }

  private struct HTTPResult: Sendable {
    let statusCode: Int
    let data: Data
  }

  private struct DeviceAuthorizationResponse: Decodable {
    let userCode: String
    let deviceAuthorizationID: String
    let interval: Int?

    private enum CodingKeys: String, CodingKey {
      case userCode = "user_code"
      case deviceAuthorizationID = "device_auth_id"
      case interval
    }
  }

  private struct PollResponse: Decodable {
    let authorizationCode: String
    let codeVerifier: String

    private enum CodingKeys: String, CodingKey {
      case authorizationCode = "authorization_code"
      case codeVerifier = "code_verifier"
    }
  }

  private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresIn: Int?

    private enum CodingKeys: String, CodingKey {
      case accessToken = "access_token"
      case refreshToken = "refresh_token"
      case idToken = "id_token"
      case expiresIn = "expires_in"
    }
  }
}
