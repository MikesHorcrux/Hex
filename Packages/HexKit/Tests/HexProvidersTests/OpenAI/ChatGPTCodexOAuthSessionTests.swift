import Foundation
import HexCore
import Testing

@testable import HexProviders

@Suite("ChatGPT Codex OAuth session")
struct ChatGPTCodexOAuthSessionTests {
  @Test
  func missingCredentialHasSignedOutStatus() async {
    let session = ChatGPTCodexOAuthSession(
      secretStore: MemorySecretStore(),
      transport: RecordingOAuthTransport()
    )

    #expect(await session.accountStatus() == .signedOut)
  }

  @Test
  func completesDeviceAuthorizationAndSuppliesSubscriptionRoutingData() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let accessToken = try Self.jwt(
      accountID: "account-test",
      expiration: now.addingTimeInterval(3_600)
    )
    let challenge = try ChatGPTCodexDeviceAuthorizationChallenge(
      userCode: "ABCD-EFGH",
      verificationURL: #require(URL(string: "https://auth.openai.com/codex/device")),
      deviceAuthorizationID: "device-test",
      pollInterval: 3,
      expiresAt: now.addingTimeInterval(900)
    )
    let transport = RecordingOAuthTransport(
      challenge: challenge,
      exchangeResponse: ChatGPTCodexOAuthTokenResponse(
        accessToken: accessToken,
        refreshToken: "refresh-test",
        idToken: nil,
        expiresIn: 3_600
      )
    )
    let secretStore = MemorySecretStore()
    let session = ChatGPTCodexOAuthSession(
      secretStore: secretStore,
      transport: transport,
      now: { now }
    )

    let started = try await session.startDeviceAuthorization()
    try await session.completeDeviceAuthorization(started)
    let authorization = try await session.authorization()

    #expect(authorization.bearerToken == accessToken)
    #expect(authorization.accountID == "account-test")
    #expect(await session.accountStatus() == .signedIn)
    #expect(await transport.exchangeCallCount == 1)
    #expect(await secretStore.lastSavedKey == .openAIChatGPTOAuth)
  }

  @Test
  func refreshesExpiringAccessTokenAndKeepsRotatedRefreshToken() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let oldAccessToken = try Self.jwt(accountID: "account-test", expiration: now)
    let newAccessToken = try Self.jwt(
      accountID: "account-test",
      expiration: now.addingTimeInterval(3_600)
    )
    let stored = StoredTokenFixture(
      accessToken: oldAccessToken,
      refreshToken: "old-refresh-token",
      idToken: nil,
      expiresAt: now,
      accountID: "account-test"
    )
    let secretStore = MemorySecretStore(
      initialValue: String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
    )
    let transport = RecordingOAuthTransport(
      refreshResponse: ChatGPTCodexOAuthTokenResponse(
        accessToken: newAccessToken,
        refreshToken: "rotated-refresh-token",
        idToken: nil,
        expiresIn: 3_600
      )
    )
    let session = ChatGPTCodexOAuthSession(
      secretStore: secretStore,
      transport: transport,
      now: { now }
    )

    let authorization = try await session.authorization()
    let saved = try #require(await secretStore.value)

    #expect(authorization.bearerToken == newAccessToken)
    #expect(await transport.lastRefreshToken == "old-refresh-token")
    #expect(saved.contains("rotated-refresh-token"))
    #expect(!saved.contains("old-refresh-token"))
  }

  private static func jwt(accountID: String, expiration: Date) throws -> String {
    let payload = try JSONSerialization.data(
      withJSONObject: [
        "https://api.openai.com/auth": ["chatgpt_account_id": accountID],
        "exp": expiration.timeIntervalSince1970,
      ],
      options: [.sortedKeys]
    )
    return "header.\(base64URL(payload)).signature"
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private actor MemorySecretStore: HexSecretStore {
    private(set) var value: String?
    private(set) var lastSavedKey: HexSecretKey?

    init(initialValue: String? = nil) {
      value = initialValue
    }

    func secret(for key: HexSecretKey) async throws -> String {
      guard key == .openAIChatGPTOAuth, let value else {
        throw TestError.missingSecret
      }
      return value
    }

    func exists(_ key: HexSecretKey) async throws -> Bool {
      key == .openAIChatGPTOAuth && value != nil
    }

    func save(_ secret: String, for key: HexSecretKey) async throws {
      value = secret
      lastSavedKey = key
    }

    func delete(_ key: HexSecretKey) async throws {
      guard key == .openAIChatGPTOAuth else { return }
      value = nil
    }
  }

  private actor RecordingOAuthTransport: ChatGPTCodexOAuthTransport {
    private let challenge: ChatGPTCodexDeviceAuthorizationChallenge?
    private let exchangeResponse: ChatGPTCodexOAuthTokenResponse?
    private let refreshResponse: ChatGPTCodexOAuthTokenResponse?
    private(set) var exchangeCallCount = 0
    private(set) var lastRefreshToken: String?

    init(
      challenge: ChatGPTCodexDeviceAuthorizationChallenge? = nil,
      exchangeResponse: ChatGPTCodexOAuthTokenResponse? = nil,
      refreshResponse: ChatGPTCodexOAuthTokenResponse? = nil
    ) {
      self.challenge = challenge
      self.exchangeResponse = exchangeResponse
      self.refreshResponse = refreshResponse
    }

    func requestDeviceAuthorization() async throws -> ChatGPTCodexDeviceAuthorizationChallenge {
      guard let challenge else { throw TestError.missingFixture }
      return challenge
    }

    func pollDeviceAuthorization(
      deviceAuthorizationID: String,
      userCode: String
    ) async throws -> ChatGPTCodexOAuthPollResult {
      _ = (deviceAuthorizationID, userCode)
      return .authorized(authorizationCode: "authorization-test", codeVerifier: "verifier-test")
    }

    func exchangeAuthorizationCode(
      _ authorizationCode: String,
      codeVerifier: String
    ) async throws -> ChatGPTCodexOAuthTokenResponse {
      _ = (authorizationCode, codeVerifier)
      exchangeCallCount += 1
      guard let exchangeResponse else { throw TestError.missingFixture }
      return exchangeResponse
    }

    func refresh(_ refreshToken: String) async throws -> ChatGPTCodexOAuthTokenResponse {
      lastRefreshToken = refreshToken
      guard let refreshResponse else { throw TestError.missingFixture }
      return refreshResponse
    }
  }

  private struct StoredTokenFixture: Codable {
    let accessToken: String
    let refreshToken: String
    let idToken: String?
    let expiresAt: Date
    let accountID: String
  }

  private enum TestError: Error, Sendable {
    case missingFixture
    case missingSecret
  }
}
