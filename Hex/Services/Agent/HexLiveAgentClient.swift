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
actor HexLiveAgentClient: HexAgentClient, HexResidentGatewayControlling, HexHeartbeatManaging,
  HexAccessibilityPermissionServicing
{
  enum ClientError: Error, Equatable, LocalizedError, Sendable {
    case applicationSupportUnavailable
    case workspaceUnavailable
    case modelMismatch(expected: String)

    var errorDescription: String? {
      switch self {
      case .applicationSupportUnavailable:
        "Hex could not locate Application Support for its local event journal."
      case .workspaceUnavailable:
        "The in-process developer gateway needs an absolute workspace folder. Set HEX_WORKSPACE_ROOT and try again."
      case .modelMismatch(let expected):
        "The selected model must match HEX_OPENAI_MODEL (\(expected))."
      }
    }
  }

  private let configuration: HexDeveloperConfiguration
  private let authorizationBroker: HexAuthorizationBroker
  private let route: HexGatewayRoute
  private let inProcessInferenceConfigurationResolver: HexInProcessInferenceConfigurationResolver
  private let residentAuthorizationTransportBuilder:
    @Sendable (HexGatewayClient) -> any HexAuthorizationDecisionSubmitting
  private var composition: HexGatewayComposition?
  private var adapter: HexGatewayClientAdapter?
  private var connectionResult: GatewayConnectionResult?
  private var connectionAttempt:
    (
      id: UUID,
      task: Task<GatewayConnectionResult, any Error>
    )?
  private var resolvedInProcessInferenceConfiguration:
    HexInProcessInferenceConfigurationResolver.Resolution?

  init(
    configuration: HexDeveloperConfiguration,
    authorizationBroker: HexAuthorizationBroker = HexAuthorizationBroker(),
    route: HexGatewayRoute? = nil,
    residentAuthorizationTransportBuilder:
      @escaping @Sendable (HexGatewayClient) -> any HexAuthorizationDecisionSubmitting =
      { client in HexGatewayAuthorizationDecisionAdapter(client: client) },
    inProcessInferenceConfigurationResolver:
      HexInProcessInferenceConfigurationResolver? = nil,
    initialGatewayAdapter: HexGatewayClientAdapter? = nil
  ) {
    let resolvedRoute = route ?? configuration.gatewayRoute
    let settingsDependencies = HexInferenceBackendSettingsDependencies.live(for: resolvedRoute)
    self.configuration = configuration
    self.authorizationBroker = authorizationBroker
    self.route = resolvedRoute
    self.inProcessInferenceConfigurationResolver =
      inProcessInferenceConfigurationResolver
      ?? HexInProcessInferenceConfigurationResolver(
        settingsStore: settingsDependencies.settingsStore,
        secretStore: settingsDependencies.secretStore,
        defaultOpenAIModelID: configuration.openAIModel
      )
    self.residentAuthorizationTransportBuilder = residentAuthorizationTransportBuilder
    adapter = initialGatewayAdapter
  }

  func connect() async throws -> GatewayConnectionResult {
    try await ensureConnected()
  }

  func disconnect() async throws {
    let pendingConnectionTask = connectionAttempt?.task
    connectionAttempt = nil
    pendingConnectionTask?.cancel()

    guard let adapter else {
      connectionResult = nil
      return
    }
    connectionResult = nil
    try await adapter.disconnect()
  }

  func startRun(_ request: GatewayStartRunRequest) async throws -> GatewayStartRunResponse {
    do {
      let adapter = try await gatewayAdapter()
      if route.kind == .developerInProcess {
        let resolution = try await inProcessInferenceConfiguration()
        let modelID: String
        switch resolution {
        case .openAI(let settings, _):
          modelID = settings.modelID
        }
        let scopedRequest = GatewayStartRunRequest(
          runID: request.runID,
          modelID: ModelID(rawValue: modelID),
          initialMessages: request.initialMessages,
          options: request.options,
          toolChoice: request.toolChoice,
          workingDirectory: try inProcessWorkspaceRoot()
        )
        return try await adapter.startRun(scopedRequest)
      }
      return try await adapter.startRun(request)
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

  func listHeartbeatSchedules() async throws -> GatewayHeartbeatScheduleList {
    do {
      let adapter = try await connectedGatewayAdapter()
      return try await adapter.listHeartbeatSchedules()
    } catch {
      clearConnectionIfUnavailable(error)
      throw error
    }
  }

  func addHeartbeatSchedule(
    _ request: GatewayHeartbeatScheduleRequest
  ) async throws -> GatewayHeartbeatScheduleList {
    do {
      let adapter = try await connectedGatewayAdapter()
      return try await adapter.addHeartbeatSchedule(request)
    } catch {
      clearConnectionIfUnavailable(error)
      throw error
    }
  }

  func removeHeartbeatSchedule(
    _ mutation: GatewayHeartbeatScheduleMutation
  ) async throws -> GatewayHeartbeatScheduleList {
    do {
      let adapter = try await connectedGatewayAdapter()
      return try await adapter.removeHeartbeatSchedule(mutation)
    } catch {
      clearConnectionIfUnavailable(error)
      throw error
    }
  }

  func pauseHeartbeatSchedule(
    _ mutation: GatewayHeartbeatScheduleMutation
  ) async throws -> GatewayHeartbeatScheduleList {
    do {
      let adapter = try await connectedGatewayAdapter()
      return try await adapter.pauseHeartbeatSchedule(mutation)
    } catch {
      clearConnectionIfUnavailable(error)
      throw error
    }
  }

  func resumeHeartbeatSchedule(
    _ mutation: GatewayHeartbeatScheduleMutation
  ) async throws -> GatewayHeartbeatScheduleList {
    do {
      let adapter = try await connectedGatewayAdapter()
      return try await adapter.resumeHeartbeatSchedule(mutation)
    } catch {
      clearConnectionIfUnavailable(error)
      throw error
    }
  }

  func accessibilityPermissionStatus() async throws -> GatewayAccessibilityPermissionStatus {
    try requireResidentPermissionRoute()
    do {
      return try await connectedGatewayAdapter().accessibilityPermissionStatus()
    } catch {
      clearConnectionIfUnavailable(error)
      throw error
    }
  }

  func requestAccessibilityPermission() async throws -> GatewayAccessibilityPermissionStatus {
    try requireResidentPermissionRoute()
    do {
      return try await connectedGatewayAdapter().requestAccessibilityPermission()
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

  private func requireResidentPermissionRoute() throws {
    guard route.kind == .residentXPC else {
      throw GatewayFailure(
        code: .transportUnavailable,
        message: "Accessibility must be checked by the resident Hex Agent."
      )
    }
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

    let attempt: (id: UUID, task: Task<GatewayConnectionResult, any Error>)
    if let connectionAttempt {
      attempt = connectionAttempt
    } else {
      let createdAttempt = (
        id: UUID(),
        task: Task { try await adapter.connect() }
      )
      connectionAttempt = createdAttempt
      attempt = createdAttempt
    }

    do {
      let result = try await attempt.task.value
      if connectionAttempt?.id == attempt.id {
        connectionResult = result
        connectionAttempt = nil
        return result
      }
      if let connectionResult {
        return connectionResult
      }
      throw CancellationError()
    } catch {
      if connectionAttempt?.id == attempt.id {
        connectionAttempt = nil
        connectionResult = nil
      }
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

    let resolution = try await inProcessInferenceConfiguration()
    let openAISettings: HexOpenAIBackendSettings
    let openAIAuthorizationProvider: any OpenAIResponsesAuthorizationProvider
    switch resolution {
    case .openAI(let settings, let selectedAuthorizationProvider):
      openAISettings = settings
      openAIAuthorizationProvider = selectedAuthorizationProvider
    }
    let workspaceRoot = try inProcessWorkspaceRoot()
    let fileSystem = try WorkspaceFileSystem(root: workspaceRoot)
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
      id: ModelID(rawValue: openAISettings.modelID),
      providerID: providerID,
      displayName: openAISettings.modelID,
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
      openAISettings.authenticationMethod == .chatGPT
      ? .chatGPTCodexSubscription
      : .platformAPI
    let providerConfiguration = try OpenAIResponsesConfiguration(
      service: service,
      models: [model]
    )
    let provider = OpenAIResponsesProvider(
      configuration: providerConfiguration,
      authorizationProvider: openAIAuthorizationProvider
    )
    let journalURL = try journalDatabaseURL()
    let compositionConfiguration = HexGatewayCompositionConfiguration(
      journalConfiguration: SQLiteAgentEventJournalConfiguration(databaseURL: journalURL),
      inferenceProvider: provider,
      toolExecutor: toolExecutor,
      authorizationProvider: authorizationProvider,
      enforcedWorkingDirectory: workspaceRoot
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

  private func inProcessInferenceConfiguration() async throws
    -> HexInProcessInferenceConfigurationResolver.Resolution
  {
    if let resolvedInProcessInferenceConfiguration {
      return resolvedInProcessInferenceConfiguration
    }
    let resolution = try await inProcessInferenceConfigurationResolver.resolve()
    resolvedInProcessInferenceConfiguration = resolution
    return resolution
  }

  private func inProcessWorkspaceRoot() throws -> URL {
    guard let workspaceRoot = configuration.workspaceRoot else {
      throw ClientError.workspaceUnavailable
    }
    return workspaceRoot
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
