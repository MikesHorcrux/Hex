import Dispatch
import HexCapabilities
import HexCore
import HexIPC
import HexPersistence
import HexProviders
@preconcurrency import Foundation
import Darwin

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
  private let authorizationBroker: HexGatewayAuthorizationBroker
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
    let fileSystem = try WorkspaceFileSystem(root: configuration.workspaceRoot)
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
      id: ModelID(rawValue: configuration.modelID),
      providerID: providerID,
      displayName: configuration.modelID,
      capabilities: [.textInput, .streaming, .toolCalling]
    )
    let providerConfiguration = try OpenAIResponsesConfiguration(models: [model])
    let inferenceProvider = OpenAIResponsesProvider(
      configuration: providerConfiguration,
      credentialProvider: configuration.makeCredentialProvider()
    )
    let compositionConfiguration = HexGatewayCompositionConfiguration(
      journalConfiguration: SQLiteAgentEventJournalConfiguration(
        databaseURL: configuration.databaseURL
      ),
      inferenceProvider: inferenceProvider,
      toolExecutor: toolExecutor,
      authorizationProvider: authorizationProvider
    )
    let composition = try await HexGatewayComposition.open(
      configuration: compositionConfiguration
    )
    let heartbeatConfiguration = HexHeartbeatSchedulerConfiguration.standard
    let heartbeatClient = HexGatewayClient(
      transport: composition.transport,
      clientID: GatewayClientID(),
      configuration: composition.gatewayConfiguration
    )
    let heartbeatRunner = try HexGatewayHeartbeatRunner(
      client: heartbeatClient,
      modelID: ModelID(rawValue: configuration.modelID),
      workspaceRoot: configuration.workspaceRoot,
      configuration: heartbeatConfiguration
    )
    let heartbeatScheduler = HexHeartbeatScheduler(
      store: JSONHexHeartbeatStore(fileURL: configuration.heartbeatStoreURL),
      runner: heartbeatRunner,
      configuration: heartbeatConfiguration
    )
    return Self(
      configuration: configuration,
      composition: composition,
      heartbeatClient: heartbeatClient,
      heartbeatScheduler: heartbeatScheduler,
      authorizationBroker: authorizationBroker
    )
  }

  private init(
    configuration: HexGatewayResidentConfiguration,
    composition: HexGatewayComposition,
    heartbeatClient: HexGatewayClient,
    heartbeatScheduler: HexHeartbeatScheduler,
    authorizationBroker: HexGatewayAuthorizationBroker
  ) {
    self.configuration = configuration
    self.composition = composition
    self.heartbeatClient = heartbeatClient
    self.heartbeatScheduler = heartbeatScheduler
    self.authorizationBroker = authorizationBroker
    listener = NSXPCListener(machServiceName: configuration.machServiceName)
    let service = composition.service
    let gatewayConfiguration = composition.gatewayConfiguration
    let broker = authorizationBroker
    listenerDelegate = HexGatewayXPCListenerDelegate(
      serviceFactory: {
        HexGatewayXPCService(
          service: service,
          configuration: gatewayConfiguration,
          authorizationDecisionHandler: { request, choice, gate in
            try await broker.submit(request, choice: choice, gate: gate)
          }
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
          try await heartbeatClient.connect()
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

    // Teardown is deliberately ordered around the shared gateway graph. The listener is closed
    // first, then the scheduler is drained, then the scheduler's client is disconnected before
    // authorization continuations and the durable journal are released.
    invalidateResources()
    await heartbeatScheduler.stop()
    await disconnectHeartbeatClientWithoutCancellation()
    await authorizationBroker.cancelAll()
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
    try await withCheckedThrowingContinuation { continuation in
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
