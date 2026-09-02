import Foundation
import HexCapabilities
import HexCore
import HexIPC
import HexMCP
import HexPersistence
import HexPersonality
import HexProviders
import HexRuntime

public struct HexGatewayComposition: Sendable {
  public static let moduleNames = [
    HexCoreModule.name,
    HexRuntimeModule.name,
    HexPersistenceModule.name,
    HexProvidersModule.name,
    HexCapabilitiesModule.name,
    HexMCPModule.name,
    HexPersonalityModule.name,
    HexIPCModule.name,
  ]

  public let journal: any AgentEventJournal
  public let runtime: AgentRuntime
  public let runDriver: HexGatewayRunDriverAdapter
  public let service: HexGatewayService
  public let transport: InProcessHexGatewayTransport
  public let gatewayConfiguration: GatewayConfiguration

  private let closeAction: @Sendable () async throws -> Void

  private init(
    journal: any AgentEventJournal,
    runtime: AgentRuntime,
    runDriver: HexGatewayRunDriverAdapter,
    service: HexGatewayService,
    transport: InProcessHexGatewayTransport,
    gatewayConfiguration: GatewayConfiguration,
    closeAction: @escaping @Sendable () async throws -> Void
  ) {
    self.journal = journal
    self.runtime = runtime
    self.runDriver = runDriver
    self.service = service
    self.transport = transport
    self.gatewayConfiguration = gatewayConfiguration
    self.closeAction = closeAction
  }

  /// Opens the durable journal and assembles one gateway service, runtime adapter, and loopback
  /// transport. The resident host may publish the same service through its separate XPC adapter;
  /// this loopback transport remains useful for local composition and deterministic tests.
  public static func open(
    configuration: HexGatewayCompositionConfiguration
  ) async throws -> Self {
    guard
      (configuration.personalityContextService == nil)
        == (configuration.personalityMemoryQuery == nil),
      !(configuration.personalityContext != nil
        && configuration.personalityContextService != nil)
    else {
      throw HexGatewayCompositionError.invalidPersonalityConfiguration
    }

    let journal: any AgentEventJournal
    let closeAction: @Sendable () async throws -> Void
    if let injectedJournal = configuration.journal {
      journal = injectedJournal
      closeAction = {}
    } else if let journalConfiguration = configuration.journalConfiguration {
      let sqliteJournal = try await SQLiteAgentEventJournal.open(
        configuration: journalConfiguration
      )
      journal = sqliteJournal
      closeAction = { try await sqliteJournal.close() }
    } else {
      throw HexGatewayCompositionError.missingJournal
    }
    let runDriver = HexGatewayRunDriverAdapter(
      inferenceProvider: configuration.inferenceProvider,
      toolExecutor: configuration.toolExecutor,
      authorizationProvider: configuration.authorizationProvider,
      journal: journal,
      runtimeConfiguration: configuration.runtimeConfiguration,
      personalityContext: configuration.personalityContext,
      personalityContextService: configuration.personalityContextService,
      personalityMemoryQuery: configuration.personalityMemoryQuery,
      enforcedModelID: configuration.enforcedModelID,
      enforcedWorkingDirectory: configuration.enforcedWorkingDirectory
    )
    let service = HexGatewayService(
      driver: runDriver,
      configuration: configuration.gatewayConfiguration
    )
    let transport = InProcessHexGatewayTransport(
      service: service,
      configuration: configuration.gatewayConfiguration
    )
    return Self(
      journal: journal,
      runtime: runDriver.runtime,
      runDriver: runDriver,
      service: service,
      transport: transport,
      gatewayConfiguration: configuration.gatewayConfiguration,
      closeAction: closeAction
    )
  }

  public static func openInert(
    databaseURL: URL,
    gatewayConfiguration: GatewayConfiguration = .standard,
    runtimeConfiguration: AgentRuntimeConfiguration = AgentRuntimeConfiguration()
  ) async throws -> Self {
    try await open(
      configuration: .inert(
        databaseURL: databaseURL,
        gatewayConfiguration: gatewayConfiguration,
        runtimeConfiguration: runtimeConfiguration
      )
    )
  }

  /// Closes the durable journal. Callers should stop or cancel active runs before closing it.
  public func close() async throws {
    try await closeAction()
  }
}
