import Foundation
import HexCore
import HexGatewayKit
import HexProviders
import Testing

@Suite("Gateway inference provider factory")
struct HexGatewayInferenceProviderFactoryTests {
  @Test
  func migrationDefaultKeepsTheExplicitOpenAIDefault() throws {
    let settings = try HexInferenceBackendSettings.migrationDefault()

    #expect(settings.selectedBackend == .openAIResponses)
    #expect(settings.openAI.modelID == HexInferenceBackendSettings.defaultOpenAIModelID)
  }

  @Test
  func defaultOpenAIProviderUsesSavedModelWithoutReadingCredential() async throws {
    let credentialProvider = RecordingCredentialProvider()
    let settings = try HexInferenceBackendSettings(openAIModelID: "saved-openai-model")

    let provider = try HexGatewayInferenceProviderFactory().makeInferenceProvider(
      for: settings,
      credentialProvider: credentialProvider
    )
    let models = try await provider.availableModels()

    #expect(models.map(\.id.rawValue) == ["saved-openai-model"])
    #expect(await credentialProvider.didReadValue() == false)
  }

  @Test
  func selectedMLXFailsClosedWhenAdapterIsNotLinked() throws {
    let settings = try HexInferenceBackendSettings(
      selectedBackend: .mlxLocal,
      openAIModelID: "openai-fallback",
      mlx: HexMLXBackendSettings(
        modelID: "local-model",
        displayName: "Local model",
        directory: URL(fileURLWithPath: "/tmp/hex-model")
      )
    )

    do {
      _ = try HexGatewayInferenceProviderFactory().makeInferenceProvider(
        for: settings,
        credentialProvider: RecordingCredentialProvider()
      )
      Issue.record("Expected an unlinked MLX adapter to fail closed.")
    } catch let error as HexGatewayInferenceProviderFactoryError {
      #expect(error == .providerUnavailable(.mlxLocal))
      #expect(error.localizedDescription.contains("MLX inference adapter"))
      #expect(!error.localizedDescription.contains("OpenAI fallback"))
    }
  }

  @Test
  func selectedCodexFailsClosedWithoutRawSubscriptionInference() throws {
    let settings = try HexInferenceBackendSettings(
      selectedBackend: .codexCompatibility,
      openAIModelID: "openai-fallback",
      codex: HexCodexCompatibilitySettings(
        executableURL: URL(fileURLWithPath: "/tmp/hex-codex")
      )
    )

    do {
      _ = try HexGatewayInferenceProviderFactory().makeInferenceProvider(
        for: settings,
        credentialProvider: RecordingCredentialProvider()
      )
      Issue.record("Expected Codex compatibility without an adapter to fail closed.")
    } catch let error as HexGatewayInferenceProviderFactoryError {
      #expect(error == .providerUnavailable(.codexCompatibility))
      #expect(error.localizedDescription.contains("app-server runtime adapter"))
      #expect(error.localizedDescription.contains("never used as raw inference"))
    }
  }

  @Test
  func injectedProviderBuildersReceiveOnlyTheirSelectedBackend() async throws {
    let factory = HexGatewayInferenceProviderFactory(
      makeMLXProvider: { settings in
        StubInferenceProvider(modelID: ModelID(rawValue: settings.modelID))
      },
      makeCodexCompatibilityProvider: { _ in
        StubInferenceProvider(modelID: ModelID(rawValue: "codex-adapter-model"))
      }
    )
    let settings = try HexInferenceBackendSettings(
      selectedBackend: .mlxLocal,
      mlx: HexMLXBackendSettings(
        modelID: "injected-mlx-model",
        displayName: "Injected MLX",
        directory: URL(fileURLWithPath: "/tmp/hex-model")
      )
    )

    let provider = try factory.makeInferenceProvider(
      for: settings,
      credentialProvider: RecordingCredentialProvider()
    )

    let models = try await provider.availableModels()
    #expect(models.map(\.id.rawValue) == ["injected-mlx-model"])
  }

  @Test
  func unconfiguredSelectedBackendHasActionableError() throws {
    let settings = try HexInferenceBackendSettings(selectedBackend: .mlxLocal)

    do {
      _ = try HexGatewayInferenceProviderFactory().makeInferenceProvider(
        for: settings,
        credentialProvider: RecordingCredentialProvider()
      )
      Issue.record("Expected an unconfigured MLX backend to fail closed.")
    } catch let error as HexGatewayInferenceProviderFactoryError {
      #expect(error == .backendNotConfigured(.mlxLocal))
      #expect(error.localizedDescription.contains("model directory"))
    }
  }

  private actor RecordingCredentialProvider: OpenAICredentialProvider {
    private var didRead = false

    func apiKey() async throws -> String {
      didRead = true
      return "test-only-key"
    }

    func didReadValue() -> Bool {
      didRead
    }
  }

  private struct StubInferenceProvider: InferenceProvider, Sendable {
    let modelID: ModelID
    let descriptor: ProviderDescriptor

    init(modelID: ModelID) {
      self.modelID = modelID
      descriptor = ProviderDescriptor(
        id: ProviderID(rawValue: "injected"),
        displayName: "Injected provider",
        capabilities: [.textInput, .streaming]
      )
    }

    func availableModels() async throws -> [ModelDescriptor] {
      [
        ModelDescriptor(
          id: modelID,
          providerID: descriptor.id,
          displayName: modelID.rawValue,
          capabilities: [.textInput, .streaming]
        )
      ]
    }

    func stream(_ request: InferenceRequest) async throws -> InferenceStream {
      _ = request
      throw StubError.unimplemented
    }
  }

  private enum StubError: Error, Sendable {
    case unimplemented
  }
}
