import HexCore
import HexProviders

/// Dependency-injected provider factory for resident inference selection.
///
/// The MLX and Codex builders are optional on purpose: this target does not link `HexMLXProvider`,
/// and Codex compatibility remains an app-server adapter seam rather than raw subscription
/// inference. A missing builder is a typed fail-closed configuration error, never an OpenAI
/// fallback.
public struct HexGatewayInferenceProviderFactory: Sendable {
  public typealias OpenAIProviderBuilder =
    @Sendable (
      HexOpenAIBackendSettings,
      any OpenAICredentialProvider
    ) throws -> any InferenceProvider
  public typealias MLXProviderBuilder =
    @Sendable (
      HexMLXBackendSettings
    ) throws -> any InferenceProvider
  public typealias CodexCompatibilityProviderBuilder =
    @Sendable (
      HexCodexCompatibilitySettings
    ) throws -> any InferenceProvider

  private let makeOpenAIProvider: OpenAIProviderBuilder
  private let makeMLXProvider: MLXProviderBuilder?
  private let makeCodexCompatibilityProvider: CodexCompatibilityProviderBuilder?

  public init(
    makeOpenAIProvider: OpenAIProviderBuilder? = nil,
    makeMLXProvider: MLXProviderBuilder? = nil,
    makeCodexCompatibilityProvider: CodexCompatibilityProviderBuilder? = nil
  ) {
    self.makeOpenAIProvider = makeOpenAIProvider ?? Self.makeDefaultOpenAIProvider
    self.makeMLXProvider = makeMLXProvider
    self.makeCodexCompatibilityProvider = makeCodexCompatibilityProvider
  }

  /// Creates the provider for exactly the persisted selection.
  public func makeInferenceProvider(
    for settings: HexInferenceBackendSettings,
    credentialProvider: any OpenAICredentialProvider
  ) throws -> any InferenceProvider {
    switch settings.selectedBackend {
    case .openAIResponses:
      guard !settings.openAI.modelID.isEmpty else {
        throw HexGatewayInferenceProviderFactoryError.backendNotConfigured(.openAIResponses)
      }
      do {
        return try makeOpenAIProvider(settings.openAI, credentialProvider)
      } catch {
        throw HexGatewayInferenceProviderFactoryError.providerInitializationFailed(
          .openAIResponses
        )
      }

    case .mlxLocal:
      guard settings.mlx.isConfigured else {
        throw HexGatewayInferenceProviderFactoryError.backendNotConfigured(.mlxLocal)
      }
      guard let makeMLXProvider else {
        throw HexGatewayInferenceProviderFactoryError.providerUnavailable(.mlxLocal)
      }
      do {
        return try makeMLXProvider(settings.mlx)
      } catch {
        throw HexGatewayInferenceProviderFactoryError.providerInitializationFailed(.mlxLocal)
      }

    case .codexCompatibility:
      guard settings.codex.isConfigured else {
        throw HexGatewayInferenceProviderFactoryError.backendNotConfigured(.codexCompatibility)
      }
      guard let makeCodexCompatibilityProvider else {
        throw HexGatewayInferenceProviderFactoryError.providerUnavailable(
          .codexCompatibility
        )
      }
      do {
        return try makeCodexCompatibilityProvider(settings.codex)
      } catch {
        throw HexGatewayInferenceProviderFactoryError.providerInitializationFailed(
          .codexCompatibility
        )
      }
    }
  }

  private static func makeDefaultOpenAIProvider(
    settings: HexOpenAIBackendSettings,
    credentialProvider: any OpenAICredentialProvider
  ) throws -> any InferenceProvider {
    let providerID = ProviderID(rawValue: "openai")
    let model = ModelDescriptor(
      id: ModelID(rawValue: settings.modelID),
      providerID: providerID,
      displayName: settings.modelID,
      capabilities: [.textInput, .streaming, .toolCalling]
    )
    let configuration = try OpenAIResponsesConfiguration(models: [model])
    return OpenAIResponsesProvider(
      configuration: configuration,
      credentialProvider: credentialProvider
    )
  }
}
