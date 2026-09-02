import Foundation
import HexCore
import HexProviders
import Testing

@testable import Hex

@Suite("Inference backend settings model")
struct HexInferenceBackendSettingsModelTests {
  @Test @MainActor
  func loadsIndependentAPIKeyAndChatGPTAuthorizationState() async {
    let manager = TrackingChatGPTAuthorizationManager(status: .signedIn)
    let secretStore = RecordingSecretStore(apiKey: "stored-api-key")
    let model = HexInferenceBackendSettingsModel(
      settingsStore: EmptySettingsStore(),
      secretStore: secretStore,
      chatGPTAuthorizationManager: manager
    )

    await model.load()

    #expect(model.hasStoredOpenAIAPIKey)
    #expect(model.chatGPTAccountStatus == .signedIn)
    #expect(await manager.accountStatusCallCount == 1)
    #expect(await secretStore.requestedSecretValueCount == 0)
  }

  @Test @MainActor
  func chatGPTLoginRequiresExplicitStartAndCompletionActions() async throws {
    let manager = TrackingChatGPTAuthorizationManager()
    let model = HexInferenceBackendSettingsModel(
      settingsStore: EmptySettingsStore(),
      secretStore: RecordingSecretStore(),
      chatGPTAuthorizationManager: manager
    )

    await model.load()
    #expect(await manager.startCallCount == 0)

    model.startChatGPTLogin()
    await waitForLoginChallenge(model)

    #expect(await manager.startCallCount == 1)
    #expect(model.chatGPTLoginChallenge?.userCode == "ABCD-EFGH")
    #expect(await manager.completeCallCount == 0)

    model.completeChatGPTLogin()
    await waitForLoginCompletion(model, manager: manager)

    #expect(await manager.completeCallCount == 1)
    #expect(model.chatGPTLoginChallenge == nil)
    #expect(model.chatGPTAccountStatus == .signedIn)
    #expect(model.statusMessage == "Signed in. Hex will use ChatGPT only for model inference.")
  }

  @Test @MainActor
  func chatGPTLogoutIsExplicitAndRedactsCredentialsFromTheModel() async {
    let manager = TrackingChatGPTAuthorizationManager(status: .signedIn)
    let model = HexInferenceBackendSettingsModel(
      settingsStore: EmptySettingsStore(),
      secretStore: RecordingSecretStore(),
      chatGPTAuthorizationManager: manager
    )

    await model.load()
    model.signOutChatGPT()
    await waitForLogout(model, manager: manager)

    #expect(await manager.signOutCallCount == 1)
    #expect(model.chatGPTAccountStatus == .signedOut)
    #expect(model.statusMessage == "Signed out of ChatGPT.")
  }

  @Test @MainActor
  func chatGPTSelectionCannotSaveBeforeSignIn() async {
    let settingsStore = RecordingSettingsStore()
    let model = HexInferenceBackendSettingsModel(
      settingsStore: settingsStore,
      secretStore: RecordingSecretStore(),
      chatGPTAuthorizationManager: TrackingChatGPTAuthorizationManager()
    )

    await model.load()
    model.openAIAuthenticationMethod = .chatGPT
    model.save()

    #expect(model.errorMessage == "Sign in with ChatGPT before saving subscription inference.")
    #expect(await settingsStore.savedSettings == nil)
  }

  @Test @MainActor
  func apiKeySavePersistsCredentialSeparatelyAndClearsEditBuffer() async {
    let settingsStore = RecordingSettingsStore()
    let secretStore = RecordingSecretStore()
    let model = HexInferenceBackendSettingsModel(
      settingsStore: settingsStore,
      secretStore: secretStore,
      chatGPTAuthorizationManager: TrackingChatGPTAuthorizationManager()
    )

    await model.load()
    model.openAIAuthenticationMethod = .apiKey
    model.openAIAPIKey = "platform-api-key"
    model.save()
    await waitForSave(model)

    #expect(await settingsStore.savedSettings?.openAI.authenticationMethod == .apiKey)
    #expect(await secretStore.storedAPIKey == "platform-api-key")
    #expect(model.openAIAPIKey.isEmpty)
  }

  @MainActor
  private func waitForLoginChallenge(_ model: HexInferenceBackendSettingsModel) async {
    for _ in 0..<100 {
      if model.chatGPTLoginChallenge != nil {
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("ChatGPT login challenge did not arrive within the test budget.")
  }

  @MainActor
  private func waitForLoginCompletion(
    _ model: HexInferenceBackendSettingsModel,
    manager: TrackingChatGPTAuthorizationManager
  ) async {
    for _ in 0..<100 {
      if await manager.completeCallCount > 0, model.chatGPTAccountStatus == .signedIn {
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("ChatGPT login completion did not settle within the test budget.")
  }

  @MainActor
  private func waitForLogout(
    _ model: HexInferenceBackendSettingsModel,
    manager: TrackingChatGPTAuthorizationManager
  ) async {
    for _ in 0..<100 {
      if await manager.signOutCallCount > 0, !model.isChatGPTLogoutInProgress {
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("ChatGPT logout did not settle within the test budget.")
  }

  @MainActor
  private func waitForSave(_ model: HexInferenceBackendSettingsModel) async {
    for _ in 0..<100 {
      if model.saveGeneration > 0 {
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Inference settings save did not settle within the test budget.")
  }

  private actor EmptySettingsStore: HexInferenceBackendSettingsStore {
    func load() async throws -> HexInferenceBackendSettings? {
      nil
    }

    func save(_ settings: HexInferenceBackendSettings) async throws {
      _ = settings
    }
  }

  private actor RecordingSettingsStore: HexInferenceBackendSettingsStore {
    private(set) var savedSettings: HexInferenceBackendSettings?

    func load() async throws -> HexInferenceBackendSettings? {
      nil
    }

    func save(_ settings: HexInferenceBackendSettings) async throws {
      savedSettings = settings
    }
  }

  private actor RecordingSecretStore: HexSecretStore {
    private(set) var storedAPIKey: String?
    private(set) var requestedSecretValueCount = 0

    init(apiKey: String? = nil) {
      storedAPIKey = apiKey
    }

    func secret(for key: HexSecretKey) async throws -> String {
      requestedSecretValueCount += 1
      guard key == .openAIAPIKey, let storedAPIKey else {
        throw TestError.missingSecret
      }
      return storedAPIKey
    }

    func exists(_ key: HexSecretKey) async throws -> Bool {
      key == .openAIAPIKey && storedAPIKey != nil
    }

    func save(_ secret: String, for key: HexSecretKey) async throws {
      guard key == .openAIAPIKey else { return }
      storedAPIKey = secret
    }

    func delete(_ key: HexSecretKey) async throws {
      _ = key
    }
  }

  private actor TrackingChatGPTAuthorizationManager: ChatGPTCodexOAuthManaging {
    private var status: ChatGPTCodexOAuthAccountStatus
    private(set) var accountStatusCallCount = 0
    private(set) var startCallCount = 0
    private(set) var completeCallCount = 0
    private(set) var signOutCallCount = 0

    init(status: ChatGPTCodexOAuthAccountStatus = .signedOut) {
      self.status = status
    }

    func accountStatus() async -> ChatGPTCodexOAuthAccountStatus {
      accountStatusCallCount += 1
      return status
    }

    func startDeviceAuthorization() async throws -> ChatGPTCodexDeviceAuthorizationChallenge {
      startCallCount += 1
      return ChatGPTCodexDeviceAuthorizationChallenge(
        userCode: "ABCD-EFGH",
        verificationURL: try #require(URL(string: "https://auth.openai.com/codex/device")),
        deviceAuthorizationID: "device-authorization-test",
        pollInterval: 5,
        expiresAt: Date().addingTimeInterval(900)
      )
    }

    func completeDeviceAuthorization(
      _ challenge: ChatGPTCodexDeviceAuthorizationChallenge
    ) async throws {
      _ = challenge
      completeCallCount += 1
      status = .signedIn
    }

    func signOut() async throws {
      signOutCallCount += 1
      status = .signedOut
    }
  }

  private enum TestError: Error, Sendable {
    case missingSecret
  }
}
