import Foundation
import HexCore
import HexProviders
import Testing

@testable import Hex

@Suite("Inference backend settings model")
struct HexInferenceBackendSettingsModelTests {
  @Test @MainActor
  func codexStatusIsReadOnlyOnExplicitRefresh() async {
    let provider = TrackingStatusProvider()
    let model = HexInferenceBackendSettingsModel(
      settingsStore: EmptySettingsStore(),
      secretStore: EmptySecretStore(),
      makeCodexStatusProvider: { _ in provider }
    )

    await model.load()
    #expect(await provider.statusCallCount == 0)

    model.codexExecutableURL = URL(fileURLWithPath: "/Users/test/bin/codex")
    model.refreshCodexAccountStatus()
    await waitForStatusRead(provider)

    #expect(await provider.statusCallCount == 1)
    #expect(model.codexAccountStatus == .signedOut)
  }

  @Test @MainActor
  func codexLoginStartsOnlyAfterUserActionAndHidesCompletionData() async {
    let provider = TrackingStatusProvider()
    let model = HexInferenceBackendSettingsModel(
      settingsStore: EmptySettingsStore(),
      secretStore: EmptySecretStore(),
      makeCodexStatusProvider: { _ in provider }
    )

    await model.load()
    #expect(await provider.startLoginCallCount == 0)

    model.codexExecutableURL = URL(fileURLWithPath: "/Users/test/bin/codex")
    model.codexLoginMode = .deviceCode
    model.startCodexLogin()
    await waitForLoginChallenge(model)

    #expect(await provider.startLoginCallCount == 1)
    if case .deviceCode(_, let userCode, _) = model.codexLoginChallenge {
      #expect(userCode == "ABCD-EFGH")
    } else {
      Issue.record("Expected the device-code login challenge.")
    }
    #expect(
      model.statusMessage
        == "Open the Codex verification page, enter the code, then check for completion."
    )
    #expect(model.errorMessage == nil)

    model.completeCodexLogin()
    await waitForLoginCompletion(model, provider: provider)

    #expect(await provider.completeLoginCallCount == 1)
    #expect(await provider.shutdownCallCount >= 1)
    #expect(model.codexLoginChallenge == nil)
    #expect(
      model.statusMessage
        == "Codex sign-in completed. Refresh to read the redacted account status."
    )
  }

  @Test @MainActor
  func codexLoginCancellationAndLogoutAreExplicitAndTerminal() async {
    let provider = TrackingStatusProvider(status: .signedIn(account: .apiKey))
    let model = HexInferenceBackendSettingsModel(
      settingsStore: EmptySettingsStore(),
      secretStore: EmptySecretStore(),
      makeCodexStatusProvider: { _ in provider }
    )

    await model.load()
    model.codexExecutableURL = URL(fileURLWithPath: "/Users/test/bin/codex")
    model.startCodexLogin()
    await waitForLoginChallenge(model)

    model.cancelCodexLogin()
    await waitForLoginCancellation(model, provider: provider)
    #expect(await provider.cancelLoginCallCount == 1)
    #expect(model.codexLoginChallenge == nil)

    model.refreshCodexAccountStatus()
    await waitForStatusRead(provider, expectedCount: 1)
    #expect(model.codexAccountStatus == .signedIn(account: .apiKey))

    model.logoutCodexAccount()
    await waitForLogout(model, provider: provider)
    #expect(await provider.logoutCallCount == 1)
    #expect(await provider.shutdownCallCount >= 2)
    #expect(model.codexAccountStatus == .signedOut)
  }

  @MainActor
  private func waitForStatusRead(_ provider: TrackingStatusProvider) async {
    await waitForStatusRead(provider, expectedCount: 1)
  }

  @MainActor
  private func waitForStatusRead(
    _ provider: TrackingStatusProvider,
    expectedCount: Int
  ) async {
    for _ in 0..<100 {
      if await provider.statusCallCount >= expectedCount {
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Codex status refresh did not complete within the test budget.")
  }

  @MainActor
  private func waitForLoginChallenge(_ model: HexInferenceBackendSettingsModel) async {
    for _ in 0..<100 {
      if model.codexLoginChallenge != nil {
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Codex login challenge did not arrive within the test budget.")
  }

  @MainActor
  private func waitForLoginCompletion(
    _ model: HexInferenceBackendSettingsModel,
    provider: TrackingStatusProvider
  ) async {
    for _ in 0..<100 {
      if await provider.completeLoginCallCount > 0 && model.codexLoginChallenge == nil {
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Codex login completion did not settle within the test budget.")
  }

  @MainActor
  private func waitForLoginCancellation(
    _ model: HexInferenceBackendSettingsModel,
    provider: TrackingStatusProvider
  ) async {
    for _ in 0..<100 {
      if await provider.cancelLoginCallCount > 0 && model.codexLoginChallenge == nil {
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Codex login cancellation did not settle within the test budget.")
  }

  @MainActor
  private func waitForLogout(
    _ model: HexInferenceBackendSettingsModel,
    provider: TrackingStatusProvider
  ) async {
    for _ in 0..<100 {
      if await provider.logoutCallCount > 0 && !model.isCodexLogoutInProgress {
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Codex logout did not settle within the test budget.")
  }

  private actor EmptySettingsStore: HexInferenceBackendSettingsStore {
    func load() async throws -> HexInferenceBackendSettings? {
      nil
    }

    func save(_ settings: HexInferenceBackendSettings) async throws {}
  }

  private actor EmptySecretStore: HexSecretStore {
    func secret(for key: HexSecretKey) async throws -> String {
      throw TestError.missingSecret
    }

    func exists(_ key: HexSecretKey) async throws -> Bool {
      false
    }

    func save(_ secret: String, for key: HexSecretKey) async throws {}

    func delete(_ key: HexSecretKey) async throws {}
  }

  private actor TrackingStatusProvider:
    CodexCompatibilityAccountStatusProviding,
    CodexCompatibilityAccountManaging
  {
    private let configuredStatus: CodexCompatibilityAccountStatus
    private(set) var statusCallCount = 0
    private(set) var startLoginCallCount = 0
    private(set) var completeLoginCallCount = 0
    private(set) var cancelLoginCallCount = 0
    private(set) var logoutCallCount = 0
    private(set) var shutdownCallCount = 0

    init(status: CodexCompatibilityAccountStatus = .signedOut) {
      configuredStatus = status
    }

    func status() async -> CodexCompatibilityAccountStatus {
      statusCallCount += 1
      return configuredStatus
    }

    func startLogin(
      _ mode: CodexChatGPTLoginMode
    ) async throws -> CodexCompatibilityLoginChallenge {
      startLoginCallCount += 1
      let loginID = try CodexLoginID(rawValue: "test-login")
      switch mode {
      case .browser:
        return .browser(
          loginID: loginID,
          authorizationURL: try #require(URL(string: "https://auth.openai.com/authorize"))
        )
      case .deviceCode:
        return .deviceCode(
          loginID: loginID,
          userCode: "ABCD-EFGH",
          verificationURL: try #require(URL(string: "https://auth.openai.com/device"))
        )
      }
    }

    func completeLogin(_ loginID: CodexLoginID) async throws {
      completeLoginCallCount += 1
    }

    func cancelLogin(_ loginID: CodexLoginID) async throws -> CodexLoginCancellationStatus {
      cancelLoginCallCount += 1
      return .cancelled
    }

    func logout() async throws {
      logoutCallCount += 1
    }

    func shutdown() async {
      shutdownCallCount += 1
    }
  }

  private enum TestError: Error, Sendable {
    case missingSecret
  }
}
