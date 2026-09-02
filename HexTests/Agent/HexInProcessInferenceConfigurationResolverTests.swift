import Foundation
import HexCore
import HexProviders
import Testing

@testable import Hex

@Suite("In-process inference configuration resolver")
struct HexInProcessInferenceConfigurationResolverTests {
  @Test
  func usesSavedOpenAIModelAndSecretStoreCredentialProvider() async throws {
    let settings = try HexInferenceBackendSettings(openAIModelID: "saved-openai-model")
    let secretStore = SecretStore(value: "saved-secret")
    let resolver = HexInProcessInferenceConfigurationResolver(
      settingsStore: SettingsStore(value: settings),
      secretStore: secretStore
    )

    let resolution = try await resolver.resolve()
    switch resolution {
    case .openAI(let modelID, let credentialProvider):
      #expect(modelID == "saved-openai-model")
      #expect(try await credentialProvider.apiKey() == "saved-secret")
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
    case .openAI(let modelID, _):
      #expect(modelID == "explicit-default-model")
    }
  }

  @Test
  func failsClosedForUnsupportedSelectedBackends() async throws {
    for backend in [HexInferenceBackendKind.mlxLocal, .codexCompatibility] {
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
    private var checkedExistence = false

    init(value: String?) {
      self.value = value
    }

    func secret(for key: HexSecretKey) async throws -> String {
      guard key == .openAIAPIKey, let value else {
        throw TestError.missingSecret
      }
      return value
    }

    func exists(_ key: HexSecretKey) async throws -> Bool {
      checkedExistence = true
      return key == .openAIAPIKey && value != nil
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
  }

  private enum TestError: Error, Sendable {
    case missingSecret
  }
}
