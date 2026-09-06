import Darwin
import Dispatch
@preconcurrency import Foundation
import HexCapabilities
import HexCore
import HexIPC
import HexMCP
import HexPersistence
import HexPersonality
import HexProviders

/// Owns the headless gateway process lifetime. It composes the real provider/tool/runtime graph,
/// advertises one user-session Mach service, and remains alive until launchd or an operator asks it
/// to stop. No launch-agent installation or registration occurs here; launchd owns process startup.
@MainActor
public final class HexGatewayResidentHost {
  public enum HostError: Swift.Error, Equatable, LocalizedError, Sendable {
    case alreadyRunning

    public var errorDescription: String? {
      switch self {
      case .alreadyRunning:
        "The resident gateway is already running."
      }
    }
  }

  public let configuration: HexGatewayResidentConfiguration

  private let composition: HexGatewayComposition
  private let heartbeatClient: HexGatewayClient
  private let heartbeatScheduler: HexHeartbeatScheduler
  private let heartbeatStore: SQLiteHexHeartbeatStore
  private let authorizationBroker: HexGatewayAuthorizationBroker
  private let mcpToolExecutors: [MCPManagedToolExecutor]
  private let toolServerController: HexGatewayToolServerController
  private let listener: NSXPCListener
  private let listenerDelegate: HexGatewayXPCListenerDelegate
  private var signalSources: [DispatchSourceSignal] = []
  private var shutdownContinuation: CheckedContinuation<Void, any Error>?
  private var shutdownRequested = false
  private var cancellationRequested = false
  private var hasStarted = false

  public static func open(
    configuration: HexGatewayResidentConfiguration
  ) async throws -> Self {
    let authorizationBroker = HexGatewayAuthorizationBroker()
    let heartbeatAuthorizationPolicy = HexHeartbeatAuthorizationPolicy(
      interactivePrompter: authorizationBroker)
    let fileSystem = try WorkspaceFileSystem(root: configuration.workspaceRoot)
    let artifactStore = try FileArtifactStore(
      rootURL: configuration.databaseURL.deletingLastPathComponent()
        .appendingPathComponent("Artifacts", isDirectory: true))
    let processExecutor = POSIXProcessExecutor(artifactWriter: artifactStore)
    let personalMemoryStore = try JSONPersonalMemoryStore(
      fileURL: configuration.personalMemoryURL
    )
    let personalMemoryToolExecutor = try PersonalMemoryToolExecutor(
      memoryStore: personalMemoryStore,
      scope: configuration.personalMemoryScope
    )
    let personalToolExecutor = try PersonalAgentToolExecutor(
      fileSystem: fileSystem,
      processExecutor: processExecutor
    )
    let mcpToolExecutors = try configuration.mcpClientSessions.map {
      try MCPManagedToolExecutor(session: $0)
    }
    let toolServerController = try HexGatewayToolServerController(executors: mcpToolExecutors)
    let routedToolExecutor = try CompositeToolExecutor(
      executors: [
        personalToolExecutor, personalMemoryToolExecutor,
        try ArtifactToolExecutor(reader: artifactStore),
      ] + mcpToolExecutors
    )
    let authorizationCenter = CapabilityAuthorizationCenter(
      prompter: heartbeatAuthorizationPolicy,
      authorizationMode: configuration.authorizationMode
    )
    let authorizationProvider = HexHeartbeatAuthorizationProvider(
      base: authorizationCenter, policy: heartbeatAuthorizationPolicy)
    let inferenceProvider = try configuration.inferenceProviderFactory.makeInferenceProvider(
      for: configuration.inferenceBackendSettings,
      authorizationProvider: configuration.makeAuthorizationProvider()
    )
    let personalityProfileStore = try JSONPersonalityProfileStore(
      fileURL: configuration.personalityProfileURL
    )
    let personalityContextService = try PersonalityContextService(
      profileStore: personalityProfileStore,
      memoryStore: personalMemoryStore
    )
    let personalityMemoryQuery = try PersonalMemoryQuery(
      scope: configuration.personalMemoryScope,
      limit: 64
    )
    let compositionConfiguration = HexGatewayCompositionConfiguration(
      journalConfiguration: SQLiteAgentEventJournalConfiguration(
        databaseURL: configuration.databaseURL
      ),
      inferenceProvider: inferenceProvider,
      toolExecutor: routedToolExecutor,
      authorizationProvider: authorizationProvider,
      personalityContextService: personalityContextService,
      personalityMemoryQuery: personalityMemoryQuery,
      enforcedWorkingDirectory: configuration.workspaceRoot,
      selfKnowledge: configuration.selfKnowledge,
      artifactWriter: artifactStore,
      artifactReader: artifactStore
    )
    let heartbeatConfiguration = try HexHeartbeatSchedulerConfiguration.standard.validated()
    let screenControlPermissionController = try configuration.managedToolLayout.map {
      try MCPPeekabooPermissionController(layout: $0)
    }
    // Nothing has been advertised or started yet. Retain each opened resource before the next
    // suspension, so cancellation or any later construction failure has one explicit unwind path.
    var openedComposition: HexGatewayComposition?
    var openedHeartbeatStore: SQLiteHexHeartbeatStore?
    do {
      try Task.checkCancellation()
      let composition = try await HexGatewayComposition.open(
        configuration: compositionConfiguration)
      openedComposition = composition
      try Task.checkCancellation()
      let heartbeatClient = HexGatewayClient(
        transport: composition.transport,
        clientID: GatewayClientID(),
        configuration: composition.gatewayConfiguration
      )
      let heartbeatRunner = try HexGatewayHeartbeatRunner(
        client: heartbeatClient,
        authorizationPolicy: heartbeatAuthorizationPolicy,
        modelID: ModelID(rawValue: configuration.modelID),
        workspaceRoot: configuration.workspaceRoot,
        configuration: heartbeatConfiguration
      )
      let heartbeatStore = try await SQLiteHexHeartbeatStore.open(
        databaseURL: configuration.heartbeatDatabaseURL,
        legacyJSONURL: configuration.heartbeatStoreURL)
      openedHeartbeatStore = heartbeatStore
      try Task.checkCancellation()
      let heartbeatScheduler = HexHeartbeatScheduler(
        store: heartbeatStore,
        runner: heartbeatRunner,
        configuration: heartbeatConfiguration,
        runInspector: HexGatewayHeartbeatRunInspector(client: heartbeatClient)
      )
      return Self(
        configuration: configuration,
        composition: composition,
        heartbeatClient: heartbeatClient,
        heartbeatScheduler: heartbeatScheduler,
        heartbeatStore: heartbeatStore,
        authorizationBroker: authorizationBroker,
        mcpToolExecutors: mcpToolExecutors,
        toolServerController: toolServerController,
        inferenceProvider: inferenceProvider,
        screenControlPermissionController: screenControlPermissionController
      )
    } catch {
      // Both close operations deliberately remain available to a cancelled caller. Preserve the
      // original startup error, while attempting every acquired resource in reverse ownership order.
      if let openedHeartbeatStore { try? await openedHeartbeatStore.close() }
      if let openedComposition { try? await openedComposition.close() }
      throw error
    }
  }

  private init(
    configuration: HexGatewayResidentConfiguration,
    composition: HexGatewayComposition,
    heartbeatClient: HexGatewayClient,
    heartbeatScheduler: HexHeartbeatScheduler,
    heartbeatStore: SQLiteHexHeartbeatStore,
    authorizationBroker: HexGatewayAuthorizationBroker,
    mcpToolExecutors: [MCPManagedToolExecutor],
    toolServerController: HexGatewayToolServerController,
    inferenceProvider: any InferenceProvider,
    screenControlPermissionController: MCPPeekabooPermissionController?
  ) {
    self.configuration = configuration
    self.composition = composition
    self.heartbeatClient = heartbeatClient
    self.heartbeatScheduler = heartbeatScheduler
    self.heartbeatStore = heartbeatStore
    self.authorizationBroker = authorizationBroker
    self.mcpToolExecutors = mcpToolExecutors
    self.toolServerController = toolServerController
    listener = NSXPCListener(machServiceName: configuration.machServiceName)
    let service = composition.service
    let gatewayConfiguration = composition.gatewayConfiguration
    let broker = authorizationBroker
    let scheduler = heartbeatScheduler
    let accessibilityController = SystemMacAccessibilityController()
    let statusHandler: @Sendable () async throws -> GatewayResidentStatus = {
      let snapshot = try await scheduler.snapshot()
      if snapshot.isPaused {
        return .paused
      }
      return await service.hasActiveRun() ? .active : .idle
    }
    let listHeartbeats: @Sendable () async throws -> GatewayHeartbeatScheduleList = {
      try HexGatewayHeartbeatScheduleMapper.list(from: await scheduler.snapshot())
    }
    let residentControlHandlers = HexGatewayResidentControlHandlers(
      status: statusHandler,
      pauseHeartbeats: {
        try await scheduler.pauseAll()
        return try await statusHandler()
      },
      resumeHeartbeats: {
        try await scheduler.resumeAll()
        return try await statusHandler()
      },
      listHeartbeats: listHeartbeats,
      addHeartbeat: { request in
        let schedule = try HexGatewayHeartbeatScheduleMapper.schedule(from: request)
        try await scheduler.add(schedule)
        return try await listHeartbeats()
      },
      removeHeartbeat: { mutation in
        let mutation = try mutation.validated()
        try await scheduler.remove(HexHeartbeatScheduleID(rawValue: mutation.scheduleID))
        return try await listHeartbeats()
      },
      pauseHeartbeat: { mutation in
        let mutation = try mutation.validated()
        try await scheduler.pause(HexHeartbeatScheduleID(rawValue: mutation.scheduleID))
        return try await listHeartbeats()
      },
      resumeHeartbeat: { mutation in
        let mutation = try mutation.validated()
        try await scheduler.resume(HexHeartbeatScheduleID(rawValue: mutation.scheduleID))
        return try await listHeartbeats()
      },
      listHeartbeatRuns: { request in
        let request = try request.validated()
        let page = try await scheduler.receipts(
          scheduleID: request.scheduleID.map(HexHeartbeatScheduleID.init(rawValue:)),
          after: HexGatewayHeartbeatRunMapper.cursor(from: request), limit: request.limit)
        return try HexGatewayHeartbeatRunMapper.page(from: page, for: request)
      }
    )
    let accessibilityPermissionHandlers = HexGatewayAccessibilityPermissionHandlers(
      status: {
        await accessibilityController.isTrusted(promptIfNeeded: false) ? .trusted : .notTrusted
      },
      request: {
        await accessibilityController.isTrusted(promptIfNeeded: true) ? .trusted : .notTrusted
      }
    )
    let screenControlPermissionHandlers: HexGatewayScreenControlPermissionHandlers
    if let screenControlPermissionController {
      screenControlPermissionHandlers = HexGatewayScreenControlPermissionHandlers(
        status: {
          do {
            let status = try await screenControlPermissionController.status()
            return GatewayScreenControlPermissionStatus(
              accessibilityGranted: status.accessibilityGranted,
              screenRecordingGranted: status.screenRecordingGranted
            )
          } catch {
            throw HexGatewayScreenControlPermissionFailureMapper.map(error)
          }
        },
        request: {
          do {
            let status = try await screenControlPermissionController.request()
            return GatewayScreenControlPermissionStatus(
              accessibilityGranted: status.accessibilityGranted,
              screenRecordingGranted: status.screenRecordingGranted
            )
          } catch {
            throw HexGatewayScreenControlPermissionFailureMapper.map(error)
          }
        }
      )
    } else {
      screenControlPermissionHandlers = .unavailable
    }
    listenerDelegate = HexGatewayXPCListenerDelegate(
      serviceFactory: {
        HexGatewayXPCService(
          service: service,
          configuration: gatewayConfiguration,
          authorizationDecisionHandler: { request, choice, gate in
            try await broker.submit(request, choice: choice, gate: gate)
          },
          residentControlHandlers: residentControlHandlers,
          accessibilityPermissionHandlers: accessibilityPermissionHandlers,
          screenControlPermissionHandlers: screenControlPermissionHandlers,
          modelCatalogHandler: { try await inferenceProvider.availableModels() },
          toolServerControlHandlers: HexGatewayToolServerControlHandlers(
            list: { try await toolServerController.health() },
            refresh: { try await toolServerController.refresh($0) }
          )
        )
      },
      admissionPolicy: configuration.connectionAdmissionPolicy
    )
  }

  /// Runs the resident process until SIGTERM, SIGINT, explicit `stop()`, or task cancellation.
  /// The listener is invalidated before the journal is closed, so no new request can race teardown.
  public func run() async throws {
    guard !hasStarted else {
      throw HostError.alreadyRunning
    }
    hasStarted = true
    let cancellationGate = HexGatewayResidentCancellationGate()

    defer {
      cancellationGate.removeCancellationHandler()
    }

    listener.delegate = listenerDelegate
    listener.setConnectionCodeSigningRequirement(
      configuration.connectionAdmissionPolicy.codeSigningRequirement
    )

    var runError: (any Error)?
    do {
      try await withTaskCancellationHandler(
        operation: {
          try Task.checkCancellation()
          guard cancellationGate.activate({ listener.activate() }) else {
            throw CancellationError()
          }
          installSignalSources()
          cancellationGate.installCancellationHandler { [weak self] in
            Task { @MainActor [weak self] in
              self?.stopForCancellation()
            }
          }
          _ = try await heartbeatClient.connect()
          try await heartbeatScheduler.start()
          try await waitForShutdown()
          try Task.checkCancellation()
        },
        onCancel: {
          cancellationGate.cancel()
        }
      )
    } catch {
      runError = error
    }

    // Seal all admissions before cancellation, but preserve existing read sessions while the
    // scheduler inspects its last receipt. Driver ownership outlives terminal replay publication.
    invalidateResources()
    await composition.service.beginShutdown()
    await authorizationBroker.cancelAll()
    await heartbeatScheduler.stop()
    // If a driver will not stop, fail without tearing down the tools/storage it still owns. A
    // cancellation request or closed listener cannot justify claiming its effects have finished.
    try await composition.service.drainRuns()
    await disconnectHeartbeatClientWithoutCancellation()
    for executor in mcpToolExecutors.reversed() {
      await executor.stop()
    }
    do {
      try await heartbeatStore.close()
    } catch {
      if runError == nil { runError = error }
    }
    do {
      try await composition.close()
    } catch {
      if runError == nil {
        runError = error
      }
    }
    if let runError {
      throw runError
    }
  }

  /// Returns the durable heartbeat state for status/control surfaces. This does not invoke the
  /// model or start a run.
  public func heartbeatSnapshot() async throws -> HexHeartbeatStoreSnapshot {
    try await heartbeatScheduler.snapshot()
  }

  /// Returns the deterministic next wake boundary, if an unpaused schedule exists.
  public func heartbeatNextWakeDate() async -> Date? {
    await heartbeatScheduler.nextWakeDate()
  }

  /// Reports whether the resident heartbeat loop is active.
  public func heartbeatIsRunning() async -> Bool {
    await heartbeatScheduler.isRunning()
  }

  /// Returns each configured MCP server's current connection/catalog health without triggering a
  /// connection attempt. A disconnected or unavailable server is retried by the next agent run.
  public func mcpServerStates() async -> [String: MCPManagedToolExecutorState] {
    var states: [String: MCPManagedToolExecutorState] = [:]
    for executor in mcpToolExecutors {
      states[executor.serverID] = await executor.currentState()
    }
    return states
  }

  /// The same cached, enabled-server snapshot exposed by the authenticated control connection.
  public func toolServerHealth() async throws -> GatewayToolServerHealth {
    try await toolServerController.health()
  }

  /// Requests an idempotent graceful shutdown. This does not install, unregister, or otherwise
  /// mutate launchd state; launchd remains responsible for deciding whether to restart the process.
  public func stop() {
    requestShutdown(isCancellation: false)
  }

  private func stopForCancellation() {
    requestShutdown(isCancellation: true)
  }

  private func requestShutdown(isCancellation: Bool) {
    if isCancellation {
      cancellationRequested = true
    }
    shutdownRequested = true
    listener.invalidate()
    let continuation = shutdownContinuation
    shutdownContinuation = nil
    if cancellationRequested {
      continuation?.resume(throwing: CancellationError())
    } else {
      continuation?.resume()
    }
  }

  private func waitForShutdown() async throws {
    try Task.checkCancellation()
    guard !shutdownRequested else {
      if cancellationRequested {
        throw CancellationError()
      }
      return
    }
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      if shutdownRequested {
        if cancellationRequested || Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          continuation.resume()
        }
      } else {
        shutdownContinuation = continuation
      }
    }
  }

  private func installSignalSources() {
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    for signalNumber in [SIGTERM, SIGINT] {
      let source = DispatchSource.makeSignalSource(
        signal: signalNumber,
        queue: .main
      )
      source.setEventHandler { [weak self] in
        Task { @MainActor in
          self?.stop()
        }
      }
      source.setCancelHandler {
        signal(signalNumber, SIG_DFL)
      }
      source.resume()
      signalSources.append(source)
    }
  }

  private func invalidateResources() {
    listener.invalidate()
    for source in signalSources {
      source.cancel()
    }
    signalSources.removeAll()
    let continuation = shutdownContinuation
    shutdownContinuation = nil
    if cancellationRequested {
      continuation?.resume(throwing: CancellationError())
    } else {
      continuation?.resume()
    }
  }

  /// `HexGatewayClient.disconnect()` checks task cancellation before doing work. Cleanup must still
  /// revoke the transport lease when the resident run was cancelled, so perform this one bounded
  /// call in an uncancelled detached task.
  private func disconnectHeartbeatClientWithoutCancellation() async {
    let client = heartbeatClient
    let disconnectTask = Task.detached(priority: nil) {
      try? await client.disconnect()
    }
    await disconnectTask.value
  }
}
