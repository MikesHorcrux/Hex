import Foundation
import HexCore
import HexProviders
import Testing

@testable import Hex

@Suite("In-process inference configuration resolver")
struct HexInProcessInferenceConfigurationResolverTests {
  @Test
  func usesSavedOpenAIModelAndAPIKeyAuthorizationProvider() async throws {
    let settings = try HexInferenceBackendSettings(openAIModelID: "saved-openai-model")
    let secretStore = SecretStore(value: "saved-secret")
    let resolver = HexInProcessInferenceConfigurationResolver(
      settingsStore: SettingsStore(value: settings),
      secretStore: secretStore
    )

    let resolution = try await resolver.resolve()
    switch resolution {
    case .openAI(let settings, let authorizationProvider):
      #expect(settings.modelID == "saved-openai-model")
      #expect(settings.authenticationMethod == .apiKey)
      #expect(try await authorizationProvider.authorization().bearerToken == "saved-secret")
    }
    #expect(await secretStore.didCheckExistence())
  }

  @Test
  func usesExplicitDefaultModelWhenSettingsFileIsAbsent() async throws {
    let secretStore = SecretStore(value: "saved-secret")
    let resolver = HexInProcessInferenceConfigurationResolver(
      settingsStore: SettingsStore(value: nil),
      secretStore: secretStore,
      defaultOpenAIModelID: "explicit-default-model"
    )

    let resolution = try await resolver.resolve()
    switch resolution {
    case .openAI(let settings, _):
      #expect(settings.modelID == "explicit-default-model")
      #expect(settings.authenticationMethod == .apiKey)
    }
  }

  @Test
  func chatGPTSelectionChecksOAuthBundleInsteadOfAPIKey() async throws {
    let settings = try HexInferenceBackendSettings(
      openAIModelID: "subscription-model",
      openAIAuthenticationMethod: .chatGPT
    )
    let secretStore = SecretStore(
      value: "redacted-oauth-bundle",
      availableKey: .openAIChatGPTOAuth
    )
    let resolver = HexInProcessInferenceConfigurationResolver(
      settingsStore: SettingsStore(value: settings),
      secretStore: secretStore
    )

    let resolution = try await resolver.resolve()
    switch resolution {
    case .openAI(let resolvedSettings, _):
      #expect(resolvedSettings.authenticationMethod == .chatGPT)
    }
    #expect(await secretStore.lastCheckedKey() == .openAIChatGPTOAuth)
  }

  @Test
  func failsClosedForUnsupportedSelectedBackend() async throws {
    let backend = HexInferenceBackendKind.mlxLocal
    let settings = try HexInferenceBackendSettings(selectedBackend: backend)
    let resolver = HexInProcessInferenceConfigurationResolver(
      settingsStore: SettingsStore(value: settings),
      secretStore: SecretStore(value: "unused")
    )

    do {
      _ = try await resolver.resolve()
      Issue.record("Expected \(backend.rawValue) to fail closed without an adapter.")
    } catch let error as HexInProcessInferenceConfigurationResolver.ResolutionError {
      #expect(error == .unsupportedBackend(backend))
      #expect(!error.localizedDescription.contains("fallback"))
    }
  }

  private actor SettingsStore: HexInferenceBackendSettingsStore {
    private let value: HexInferenceBackendSettings?

    init(value: HexInferenceBackendSettings?) {
      self.value = value
    }

    func load() async throws -> HexInferenceBackendSettings? {
      value
    }

    func save(_ settings: HexInferenceBackendSettings) async throws {
      _ = settings
    }
  }

  private actor SecretStore: HexSecretStore {
    private let value: String?
    private let availableKey: HexSecretKey
    private var checkedExistence = false
    private var checkedKey: HexSecretKey?

    init(value: String?, availableKey: HexSecretKey = .openAIAPIKey) {
      self.value = value
      self.availableKey = availableKey
    }

    func secret(for key: HexSecretKey) async throws -> String {
      guard key == availableKey, let value else {
        throw TestError.missingSecret
      }
      return value
    }

    func exists(_ key: HexSecretKey) async throws -> Bool {
      checkedExistence = true
      checkedKey = key
      return key == availableKey && value != nil
    }

    func save(_ secret: String, for key: HexSecretKey) async throws {
      _ = (secret, key)
    }

    func delete(_ key: HexSecretKey) async throws {
      _ = key
    }

    func didCheckExistence() -> Bool {
      checkedExistence
    }

    func lastCheckedKey() -> HexSecretKey? {
      checkedKey
    }
  }

  private enum TestError: Error, Sendable {
    case missingSecret
  }
}
