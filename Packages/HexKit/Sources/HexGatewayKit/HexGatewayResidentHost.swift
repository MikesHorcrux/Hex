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
    return Self(
      configuration: configuration,
      composition: composition,
      authorizationBroker: authorizationBroker
    )
  }

  private init(
    configuration: HexGatewayResidentConfiguration,
    composition: HexGatewayComposition,
    authorizationBroker: HexGatewayAuthorizationBroker
  ) {
    self.configuration = configuration
    self.composition = composition
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
          authorizationDecisionHandler: { request, choice in
            try await broker.submit(request, choice: choice)
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
    try Task.checkCancellation()
    hasStarted = true
    let cancellationGate = HexGatewayResidentCancellationGate()

    defer {
      cancellationGate.removeCancellationHandler()
      invalidateResources()
    }

    listener.delegate = listenerDelegate
    listener.setConnectionCodeSigningRequirement(
      configuration.connectionAdmissionPolicy.codeSigningRequirement
    )

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
        try await waitForShutdown()
        try Task.checkCancellation()
      },
      onCancel: {
        cancellationGate.cancel()
      }
    )
    await authorizationBroker.cancelAll()
    try await composition.close()
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
}
