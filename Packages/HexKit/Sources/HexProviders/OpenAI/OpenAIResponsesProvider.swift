import HexCore

public actor OpenAIResponsesProvider: InferenceProvider {
  public nonisolated let descriptor: ProviderDescriptor
  let configuration: OpenAIResponsesConfiguration
  let credentialProvider: any OpenAICredentialProvider
  let transport: any OpenAIResponsesTransport
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
    credentialProvider: any OpenAICredentialProvider,
    transport: any OpenAIResponsesTransport = URLSessionOpenAIResponsesTransport()
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
    self.credentialProvider = credentialProvider
    self.transport = transport
  }

  public func availableModels() async throws -> [ModelDescriptor] {
    configuration.models
  }
}
