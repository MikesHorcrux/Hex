import Foundation
import HexCore

/// Hex-owned OAuth session used only to authorize Hex's own Responses requests.
public actor ChatGPTCodexOAuthSession:
  ChatGPTCodexOAuthManaging,
  OpenAIResponsesAuthorizationProvider
{
  private static let refreshSkew: TimeInterval = 120
  private static let defaultTokenLifetime: TimeInterval = 60 * 60

  private let secretStore: any HexSecretStore
  private let transport: any ChatGPTCodexOAuthTransport
  private let now: @Sendable () -> Date

  public init(
    secretStore: any HexSecretStore,
    transport: any ChatGPTCodexOAuthTransport = URLSessionChatGPTCodexOAuthTransport(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.secretStore = secretStore
    self.transport = transport
    self.now = now
  }

  public func accountStatus() async -> ChatGPTCodexOAuthAccountStatus {
    do {
      _ = try await loadTokenSet()
      return .signedIn
    } catch ChatGPTCodexOAuthError.missingCredentials {
      return .signedOut
    } catch {
      return .unavailable
    }
  }

  public func startDeviceAuthorization() async throws
    -> ChatGPTCodexDeviceAuthorizationChallenge
  {
    try Task.checkCancellation()
    return try await transport.requestDeviceAuthorization()
  }

  public func completeDeviceAuthorization(
    _ challenge: ChatGPTCodexDeviceAuthorizationChallenge
  ) async throws {
    while now() < challenge.expiresAt {
      try Task.checkCancellation()
      switch try await transport.pollDeviceAuthorization(
        deviceAuthorizationID: challenge.deviceAuthorizationID,
        userCode: challenge.userCode
      ) {
      case .pending:
        try await Task.sleep(for: .seconds(challenge.pollInterval))
      case .authorized(let authorizationCode, let codeVerifier):
        let response = try await transport.exchangeAuthorizationCode(
          authorizationCode,
          codeVerifier: codeVerifier
        )
        let tokenSet = try makeTokenSet(from: response, priorRefreshToken: nil)
        try await save(tokenSet)
        return
      }
    }
    throw ChatGPTCodexOAuthError.authorizationTimedOut
  }

  public func signOut() async throws {
    try await secretStore.delete(.openAIChatGPTOAuth)
  }

  public func authorization() async throws -> OpenAIResponsesAuthorization {
    try Task.checkCancellation()
    var tokenSet = try await loadTokenSet()
    if tokenSet.expiresAt <= now().addingTimeInterval(Self.refreshSkew) {
      let refreshed: ChatGPTCodexOAuthTokenResponse
      do {
        refreshed = try await transport.refresh(tokenSet.refreshToken)
      } catch ChatGPTCodexOAuthError.rateLimited {
        throw ChatGPTCodexOAuthError.rateLimited
      } catch {
        throw ChatGPTCodexOAuthError.refreshRejected
      }
      tokenSet = try makeTokenSet(
        from: refreshed,
        priorRefreshToken: tokenSet.refreshToken
      )
      try await save(tokenSet)
    }
    return OpenAIResponsesAuthorization(
      bearerToken: tokenSet.accessToken,
      accountID: tokenSet.accountID
    )
  }

  private func loadTokenSet() async throws -> ChatGPTCodexOAuthTokenSet {
    let exists: Bool
    do {
      exists = try await secretStore.exists(.openAIChatGPTOAuth)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ChatGPTCodexOAuthError.invalidCredentials
    }
    guard exists else {
      throw ChatGPTCodexOAuthError.missingCredentials
    }

    let encoded: String
    do {
      encoded = try await secretStore.secret(for: .openAIChatGPTOAuth)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ChatGPTCodexOAuthError.invalidCredentials
    }
    guard let data = encoded.data(using: .utf8), data.count <= 64 * 1_024 else {
      throw ChatGPTCodexOAuthError.invalidCredentials
    }
    let tokenSet: ChatGPTCodexOAuthTokenSet
    do {
      tokenSet = try JSONDecoder().decode(ChatGPTCodexOAuthTokenSet.self, from: data)
    } catch {
      throw ChatGPTCodexOAuthError.invalidCredentials
    }
    try validate(tokenSet)
    return tokenSet
  }

  private func makeTokenSet(
    from response: ChatGPTCodexOAuthTokenResponse,
    priorRefreshToken: String?
  ) throws -> ChatGPTCodexOAuthTokenSet {
    let refreshToken = response.refreshToken ?? priorRefreshToken
    guard let refreshToken else { throw ChatGPTCodexOAuthError.invalidCredentials }
    let accountID =
      Self.accountID(from: response.idToken)
      ?? Self.accountID(from: response.accessToken)
    guard let accountID else { throw ChatGPTCodexOAuthError.invalidCredentials }
    let expiresAt: Date
    if let seconds = response.expiresIn, (1...7 * 24 * 60 * 60).contains(seconds) {
      expiresAt = now().addingTimeInterval(TimeInterval(seconds))
    } else if let expiration = Self.expiration(from: response.accessToken) {
      expiresAt = expiration
    } else {
      expiresAt = now().addingTimeInterval(Self.defaultTokenLifetime)
    }
    let tokenSet = ChatGPTCodexOAuthTokenSet(
      accessToken: response.accessToken,
      refreshToken: refreshToken,
      idToken: response.idToken,
      expiresAt: expiresAt,
      accountID: accountID
    )
    try validate(tokenSet)
    return tokenSet
  }

  private func save(_ tokenSet: ChatGPTCodexOAuthTokenSet) async throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data: Data
    do {
      data = try encoder.encode(tokenSet)
    } catch {
      throw ChatGPTCodexOAuthError.invalidCredentials
    }
    guard data.count <= 64 * 1_024 else {
      throw ChatGPTCodexOAuthError.invalidCredentials
    }
    try await secretStore.save(String(decoding: data, as: UTF8.self), for: .openAIChatGPTOAuth)
  }

  private func validate(_ tokenSet: ChatGPTCodexOAuthTokenSet) throws {
    guard
      Self.isValidOpaqueValue(tokenSet.accessToken, maximumBytes: 32 * 1_024),
      Self.isValidOpaqueValue(tokenSet.refreshToken, maximumBytes: 32 * 1_024),
      Self.isValidOpaqueValue(tokenSet.accountID, maximumBytes: 512),
      tokenSet.expiresAt.timeIntervalSince1970.isFinite
    else {
      throw ChatGPTCodexOAuthError.invalidCredentials
    }
    if let idToken = tokenSet.idToken,
      !Self.isValidOpaqueValue(idToken, maximumBytes: 32 * 1_024)
    {
      throw ChatGPTCodexOAuthError.invalidCredentials
    }
  }

  private static func accountID(from token: String?) -> String? {
    guard let claims = claims(from: token) else { return nil }
    if let accountID = claims["chatgpt_account_id"] as? String,
      isValidOpaqueValue(accountID, maximumBytes: 512)
    {
      return accountID
    }
    if let auth = claims["https://api.openai.com/auth"] as? [String: Any],
      let accountID = auth["chatgpt_account_id"] as? String,
      isValidOpaqueValue(accountID, maximumBytes: 512)
    {
      return accountID
    }
    return nil
  }

  private static func expiration(from token: String) -> Date? {
    guard let claims = claims(from: token) else { return nil }
    if let expiration = claims["exp"] as? Double, expiration.isFinite {
      return Date(timeIntervalSince1970: expiration)
    }
    if let expiration = claims["exp"] as? Int, expiration > 0 {
      return Date(timeIntervalSince1970: TimeInterval(expiration))
    }
    return nil
  }

  /// JWT claims are used only as routing metadata. OpenAI still verifies the signed bearer token.
  private static func claims(from token: String?) -> [String: Any]? {
    guard let token else { return nil }
    let components = token.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3 else { return nil }
    var payload = String(components[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = payload.count % 4
    if remainder != 0 {
      payload.append(String(repeating: "=", count: 4 - remainder))
    }
    guard
      let data = Data(base64Encoded: payload),
      data.count <= 64 * 1_024,
      let object = try? JSONSerialization.jsonObject(with: data),
      let claims = object as? [String: Any]
    else {
      return nil
    }
    return claims
  }

  private static func isValidOpaqueValue(_ value: String, maximumBytes: Int) -> Bool {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= maximumBytes else { return false }
    return bytes.allSatisfy { (0x21...0x7E).contains($0) }
  }
}
