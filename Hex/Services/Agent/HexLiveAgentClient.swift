import Foundation
import HexCapabilities
import HexCore
import HexGatewayKit
import HexIPC
import HexPersistence
import HexProviders

/// Lazily selects the resident XPC gateway first. The in-process composition is retained only as an
/// explicit developer fallback, so a missing or unavailable resident service never becomes a
/// silently privileged app-local agent.
actor HexLiveAgentClient: HexAgentClient, HexResidentGatewayControlling {
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
  private let route: HexGatewayRoute
  private let residentAuthorizationTransportBuilder:
    @Sendable (HexGatewayClient) -> any HexAuthorizationDecisionSubmitting
  private var composition: HexGatewayComposition?
  private var adapter: HexGatewayClientAdapter?
  private var connectionResult: GatewayConnectionResult?

  init(
    configuration: HexDeveloperConfiguration,
    authorizationBroker: HexAuthorizationBroker = HexAuthorizationBroker(),
    route: HexGatewayRoute? = nil,
    residentAuthorizationTransportBuilder:
      @escaping @Sendable (HexGatewayClient) -> any HexAuthorizationDecisionSubmitting =
      { client in HexGatewayAuthorizationDecisionAdapter(client: client) },
    initialGatewayAdapter: HexGatewayClientAdapter? = nil
  ) {
    self.configuration = configuration
    self.authorizationBroker = authorizationBroker
    self.route = route ?? configuration.gatewayRoute
    self.residentAuthorizationTransportBuilder = residentAuthorizationTransportBuilder
    adapter = initialGatewayAdapter
  }

  func connect() async throws -> GatewayConnectionResult {
    try await ensureConnected()
  }

  func disconnect() async throws {
    guard let adapter else {
      connectionResult = nil
      return
    }
    connectionResult = nil
    try await adapter.disconnect()
  }

  func startRun(_ request: GatewayStartRunRequest) async throws -> GatewayStartRunResponse {
    do {
      if route.kind == .developerInProcess {
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
      return try await gatewayAdapter().startRun(request)
    } catch {
      clearConnectionIfUnavailable(error)
      throw error
    }
  }

  func eventRecords(
    for runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) async throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error> {
    do {
      return try await gatewayAdapter().eventRecords(for: runID, invocationID: invocationID)
    } catch {
      clearConnectionIfUnavailable(error)
      throw error
    }
  }

  func cancelRun(_ request: GatewayCancelRunRequest) async throws -> GatewayCancelRunResponse {
    do {
      return try await gatewayAdapter().cancelRun(request)
    } catch {
      clearConnectionIfUnavailable(error)
      throw error
    }
  }

  func shouldApply(_ envelope: GatewayEventEnvelope) async throws -> Bool {
    do {
      return try await gatewayAdapter().shouldApply(envelope)
    } catch {
      clearConnectionIfUnavailable(error)
      throw error
    }
  }

  func acknowledge(_ envelope: GatewayEventEnvelope) async throws {
    do {
      try await gatewayAdapter().acknowledge(envelope)
    } catch {
      clearConnectionIfUnavailable(error)
      throw error
    }
  }

  func decideAuthorization(
    _ request: AuthorizationRequest,
    choice: AuthorizationDecisionChoice
  ) async throws {
    do {
      try await gatewayAdapter().decideAuthorization(request, choice: choice)
    } catch {
      clearConnectionIfUnavailable(error)
      throw error
    }
  }

  /// Reads resident state through the same adapter used by interactive runs. A menu-bar-only launch
  /// lazily establishes that adapter's XPC connection; the resident route never falls back to an
  /// in-process composition.
  func status() async throws -> HexResidentGatewayStatus {
    do {
      let adapter = try await connectedGatewayAdapter()
      let status = try await adapter.status()
      return appStatus(from: status)
    } catch let failure as GatewayFailure
      where failure.code == .notConnected
      || failure.code == .transportUnavailable
      || failure.code == .disconnected
    {
      connectionResult = nil
      return .unavailable
    } catch {
      clearConnectionIfUnavailable(error)
      throw error
    }
  }

  func pauseHeartbeats() async throws -> HexResidentGatewayStatus {
    do {
      let adapter = try await connectedGatewayAdapter()
      let status = try await adapter.pauseHeartbeats()
      return appStatus(from: status)
    } catch {
      clearConnectionIfUnavailable(error)
      throw error
    }
  }

  func resumeHeartbeats() async throws -> HexResidentGatewayStatus {
    do {
      let adapter = try await connectedGatewayAdapter()
      let status = try await adapter.resumeHeartbeats()
      return appStatus(from: status)
    } catch {
      clearConnectionIfUnavailable(error)
      throw error
    }
  }

  private func connectedGatewayAdapter() async throws -> HexGatewayClientAdapter {
    let adapter = try await gatewayAdapter()
    guard route.kind == .residentXPC else {
      return adapter
    }
    _ = try await ensureConnected(using: adapter)
    return adapter
  }

  private func ensureConnected() async throws -> GatewayConnectionResult {
    let adapter = try await gatewayAdapter()
    return try await ensureConnected(using: adapter)
  }

  private func ensureConnected(
    using adapter: HexGatewayClientAdapter
  ) async throws -> GatewayConnectionResult {
    if let connectionResult {
      return connectionResult
    }

    do {
      let result = try await adapter.connect()
      connectionResult = result
      return result
    } catch {
      connectionResult = nil
      throw error
    }
  }

  private func clearConnectionIfUnavailable(_ error: any Error) {
    guard let failure = error as? GatewayFailure else {
      return
    }
    switch failure.code {
    case .notConnected, .transportUnavailable, .disconnected:
      connectionResult = nil
    default:
      break
    }
  }

  private func appStatus(
    from status: GatewayResidentStatus
  ) -> HexResidentGatewayStatus {
    switch status {
    case .unavailable:
      .unavailable
    case .idle:
      .idle
    case .active:
      .active
    case .paused:
      .paused
    }
  }

  private func gatewayAdapter() async throws -> HexGatewayClientAdapter {
    if let adapter {
      return adapter
    }

    if route.kind == .residentXPC {
      let gatewayClient = HexGatewayClient(
        transport: XPCGatewayTransport(machServiceName: route.machServiceName)
      )
      let adapter = HexGatewayClientAdapter(
        client: gatewayClient,
        authorizationTransport: residentAuthorizationTransportBuilder(gatewayClient)
      )
      self.adapter = adapter
      return adapter
    }

    let values = try configuration.liveValues()
    let fileSystem = try WorkspaceFileSystem(root: values.workspaceRoot)
    let processExecutor = POSIXProcessExecutor()
    let toolExecutor = try PersonalAgentToolExecutor(
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
    let authorizationTransport = HexInProcessAuthorizationDecisionTransport(
      broker: authorizationBroker
    )
    let adapter = HexGatewayClientAdapter(
      client: gatewayClient,
      authorizationTransport: authorizationTransport
    )
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
