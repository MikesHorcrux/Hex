import HexCore
import HexProviders

/// Dependency-injected provider factory for resident inference selection.
///
/// The MLX builder is optional because this target does not link `HexMLXProvider`. OpenAI API-key
/// and ChatGPT/Codex subscription inference share Hex's Responses provider and differ only in
/// authorization and their security-pinned first-party endpoint.
public struct HexGatewayInferenceProviderFactory: Sendable {
  public typealias OpenAIProviderBuilder =
    @Sendable (
      HexOpenAIBackendSettings,
      any OpenAIResponsesAuthorizationProvider
    ) throws -> any InferenceProvider
  public typealias MLXProviderBuilder =
    @Sendable (
      HexMLXBackendSettings
    ) throws -> any InferenceProvider
  public typealias LlamaCppProviderBuilder =
    @Sendable (
      HexLlamaCppBackendSettings
    ) throws -> any InferenceProvider
  private let makeOpenAIProvider: OpenAIProviderBuilder
  private let makeMLXProvider: MLXProviderBuilder?
  private let makeLlamaCppProvider: LlamaCppProviderBuilder?

  public init(
    makeOpenAIProvider: OpenAIProviderBuilder? = nil,
    makeMLXProvider: MLXProviderBuilder? = nil,
    makeLlamaCppProvider: LlamaCppProviderBuilder? = nil,
    makeChatGPTModelCatalog:
      @escaping @Sendable (any OpenAIResponsesAuthorizationProvider) ->
      any OpenAIModelCatalogLoading = {
        OpenAIChatGPTModelCatalog(authorizationProvider: $0)
      }
  ) {
    self.makeOpenAIProvider =
      makeOpenAIProvider ?? { settings, authorization in
        try Self.makeDefaultOpenAIProvider(
          settings: settings, authorizationProvider: authorization,
          modelCatalog: settings.authenticationMethod == .chatGPT
            ? makeChatGPTModelCatalog(authorization) : nil
        )
      }
    self.makeMLXProvider = makeMLXProvider
    self.makeLlamaCppProvider = makeLlamaCppProvider
  }

  /// Creates the provider for exactly the persisted selection.
  public func makeInferenceProvider(
    for settings: HexInferenceBackendSettings,
    authorizationProvider: any OpenAIResponsesAuthorizationProvider
  ) throws -> any InferenceProvider {
    switch settings.selectedBackend {
    case .openAIResponses:
      guard !settings.openAI.modelID.isEmpty else {
        throw HexGatewayInferenceProviderFactoryError.backendNotConfigured(.openAIResponses)
      }
      do {
        return try makeOpenAIProvider(settings.openAI, authorizationProvider)
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

    case .llamaCppLocal:
      guard settings.llamaCpp.isConfigured else {
        throw HexGatewayInferenceProviderFactoryError.backendNotConfigured(.llamaCppLocal)
      }
      guard let makeLlamaCppProvider else {
        throw HexGatewayInferenceProviderFactoryError.providerUnavailable(.llamaCppLocal)
      }
      do {
        return try makeLlamaCppProvider(settings.llamaCpp)
      } catch {
        throw HexGatewayInferenceProviderFactoryError.providerInitializationFailed(.llamaCppLocal)
      }

    }
  }

  private static func makeDefaultOpenAIProvider(
    settings: HexOpenAIBackendSettings,
    authorizationProvider: any OpenAIResponsesAuthorizationProvider,
    modelCatalog: (any OpenAIModelCatalogLoading)?
  ) throws -> any InferenceProvider {
    let providerID = ProviderID(rawValue: "openai")
    let model = ModelDescriptor(
      id: ModelID(rawValue: settings.modelID),
      providerID: providerID,
      displayName: settings.modelID,
      capabilities: [
        .textInput,
        .imageInput,
        .streaming,
        .toolCalling,
        .parallelToolCalling,
        .reasoningSummary,
      ]
    )
    let service: OpenAIResponsesService =
      settings.authenticationMethod == .chatGPT
      ? .chatGPTCodexSubscription
      : .platformAPI
    let configuration = try OpenAIResponsesConfiguration(
      service: service,
      models: [model]
    )
    return OpenAIResponsesProvider(
      configuration: configuration,
      authorizationProvider: authorizationProvider,
      modelCatalog: modelCatalog
    )
  }
}
