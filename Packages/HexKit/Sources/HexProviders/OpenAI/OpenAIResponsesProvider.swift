import Foundation
import HexCore
import OSLog

public actor OpenAIResponsesProvider: InferenceProvider {
  public nonisolated let descriptor: ProviderDescriptor
  public nonisolated let supportsServerOutputTokenLimit: Bool
  let configuration: OpenAIResponsesConfiguration
  let authorizationProvider: any OpenAIResponsesAuthorizationProvider
  let transport: any OpenAIResponsesTransport
  let modelCatalog: (any OpenAIModelCatalogLoading)?
  var modelCatalogRetryAfter: Date?
  let logger = Logger(subsystem: "com.lunarmothstudios.Hex", category: "openai-responses")
  var issuedResponseIDs = Set<String>()
  var issuedResponseIDBytes = 0
  var responseIdentifierTrackingExhausted = false
  var serverStates: [String: OpenAIServerContinuationState] = [:]
  var serverStateOrder: [String] = []
  var serverStateBytes = 0
  var localStates: [String: OpenAILocalContinuationState] = [:]
  var localStateOrder: [String] = []
  var localStateBytes = 0

  public init(
    configuration: OpenAIResponsesConfiguration,
    authorizationProvider: any OpenAIResponsesAuthorizationProvider,
    transport: any OpenAIResponsesTransport = URLSessionOpenAIResponsesTransport(),
    modelCatalog: (any OpenAIModelCatalogLoading)? = nil
  ) {
    var capabilities = Set<InferenceCapability>()
    for model in configuration.models {
      capabilities.formUnion(model.capabilities)
    }
    capabilities.formIntersection([
      .textInput,
      .imageInput,
      .streaming,
      .toolCalling,
      .parallelToolCalling,
      .reasoningSummary,
    ])

    descriptor = ProviderDescriptor(
      id: configuration.providerID,
      displayName: configuration.displayName,
      capabilities: capabilities
    )
    self.configuration = configuration
    supportsServerOutputTokenLimit = configuration.service == .platformAPI
    self.authorizationProvider = authorizationProvider
    self.transport = transport
    self.modelCatalog = modelCatalog
  }

  public init(
    configuration: OpenAIResponsesConfiguration,
    credentialProvider: any OpenAICredentialProvider,
    transport: any OpenAIResponsesTransport = URLSessionOpenAIResponsesTransport()
  ) {
    self.init(
      configuration: configuration,
      authorizationProvider: credentialProvider,
      transport: transport
    )
  }

  public func availableModels() async throws -> [ModelDescriptor] {
    if let modelCatalog {
      if let modelCatalogRetryAfter, modelCatalogRetryAfter > Date() { return configuration.models }
      do {
        let models = try await modelCatalog.availableModels()
        try Task.checkCancellation()
        modelCatalogRetryAfter = nil
        return models
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if Task.isCancelled { throw CancellationError() }
        // Discovery is optional. Retain only the explicitly configured model when unavailable;
        // an unavailable selected model is never substituted for a different model in a request.
        logger.notice("Model discovery unavailable; using configured model metadata.")
        modelCatalogRetryAfter = Date().addingTimeInterval(30)
      }
    }
    return configuration.models
  }
}
