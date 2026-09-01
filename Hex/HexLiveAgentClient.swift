import Foundation
import HexCapabilities
import HexCore
import HexGatewayKit
import HexIPC
import HexPersistence
import HexProviders

/// Lazily composes the real developer-mode agent in the app process. This intentionally uses the
/// in-process transport until a registered XPC/launchd boundary exists; the prepared XPC transport
/// is not presented as active here.
actor HexLiveAgentClient: HexAgentClient {
  enum ClientError: Error, Equatable, LocalizedError, Sendable {
    case applicationSupportUnavailable
    case modelMismatch(expected: String)

    var errorDescription: String? {
      switch self {
      case .applicationSupportUnavailable:
        "Hex could not locate Application Support for its local event journal."
      case .modelMismatch(let expected):
        "The selected model must match HEX_OPENAI_MODEL (\(expected))."
      }
    }
  }

  private let configuration: HexDeveloperConfiguration
  private let authorizationBroker: HexAuthorizationBroker
  private var composition: HexGatewayComposition?
  private var adapter: HexGatewayClientAdapter?

  init(
    configuration: HexDeveloperConfiguration,
    authorizationBroker: HexAuthorizationBroker = HexAuthorizationBroker()
  ) {
    self.configuration = configuration
    self.authorizationBroker = authorizationBroker
  }

  func connect() async throws -> GatewayConnectionResult {
    try await gatewayAdapter().connect()
  }

  func disconnect() async throws {
    guard let adapter else {
      return
    }
    try await adapter.disconnect()
  }

  func startRun(_ request: GatewayStartRunRequest) async throws -> GatewayStartRunResponse {
    let values = try configuration.liveValues()
    guard request.modelID.rawValue == values.modelID else {
      throw ClientError.modelMismatch(expected: values.modelID)
    }
    let scopedRequest = GatewayStartRunRequest(
      runID: request.runID,
      modelID: request.modelID,
      initialMessages: request.initialMessages,
      options: request.options,
      toolChoice: request.toolChoice,
      workingDirectory: values.workspaceRoot
    )
    return try await gatewayAdapter().startRun(scopedRequest)
  }

  func eventRecords(
    for runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) async throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error> {
    try await gatewayAdapter().eventRecords(for: runID, invocationID: invocationID)
  }

  func cancelRun(_ request: GatewayCancelRunRequest) async throws -> GatewayCancelRunResponse {
    try await gatewayAdapter().cancelRun(request)
  }

  func shouldApply(_ envelope: GatewayEventEnvelope) async throws -> Bool {
    try await gatewayAdapter().shouldApply(envelope)
  }

  func acknowledge(_ envelope: GatewayEventEnvelope) async throws {
    try await gatewayAdapter().acknowledge(envelope)
  }

  func decideAuthorization(
    _ request: AuthorizationRequest,
    choice: AuthorizationDecisionChoice
  ) async throws {
    try await gatewayAdapter().decideAuthorization(request, choice: choice)
  }

  private func gatewayAdapter() async throws -> HexGatewayClientAdapter {
    if let adapter {
      return adapter
    }

    let values = try configuration.liveValues()
    let fileSystem = try WorkspaceFileSystem(root: values.workspaceRoot)
    let processExecutor = POSIXProcessExecutor()
    let toolExecutor = try WorkspaceCodingToolExecutor(
      fileSystem: fileSystem,
      processExecutor: processExecutor
    )
    let authorizationProvider = CapabilityAuthorizationCenter(
      prompter: authorizationBroker
    )
    let providerID = ProviderID(rawValue: "openai")
    let model = ModelDescriptor(
      id: ModelID(rawValue: values.modelID),
      providerID: providerID,
      displayName: values.modelID,
      capabilities: [.textInput, .streaming, .toolCalling]
    )
    let providerConfiguration = try OpenAIResponsesConfiguration(models: [model])
    let provider = OpenAIResponsesProvider(
      configuration: providerConfiguration,
      credentialProvider: HexOpenAICredentialProvider(apiKey: values.apiKey)
    )
    let journalURL = try journalDatabaseURL()
    let compositionConfiguration = HexGatewayCompositionConfiguration(
      journalConfiguration: SQLiteAgentEventJournalConfiguration(databaseURL: journalURL),
      inferenceProvider: provider,
      toolExecutor: toolExecutor,
      authorizationProvider: authorizationProvider
    )
    let composition = try await HexGatewayComposition.open(
      configuration: compositionConfiguration
    )
    let gatewayClient = HexGatewayClient(transport: composition.transport)
    let authorizationBroker = self.authorizationBroker
    let adapter = HexGatewayClientAdapter(client: gatewayClient) { request, choice in
      try await authorizationBroker.submit(request, choice: choice)
    }
    self.composition = composition
    self.adapter = adapter
    return adapter
  }

  private func journalDatabaseURL() throws -> URL {
    guard
      let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      throw ClientError.applicationSupportUnavailable
    }
    return
      applicationSupport
      .appendingPathComponent("Hex", isDirectory: true)
      .appendingPathComponent("agent-events.sqlite", isDirectory: false)
  }
}
