import Foundation
import HexCapabilities
import HexCore
import HexIPC
import HexPersistence
import HexPersonality
import HexProviders
import HexRuntime

/// All gateway-side dependencies are selected by the owning composition root. The inert factory is
/// deliberately offline and deny-by-default; a host supplies an inference provider and tools when
/// it is ready to grant those capabilities.
public struct HexGatewayCompositionConfiguration: Sendable {
  public let journalConfiguration: SQLiteAgentEventJournalConfiguration?
  public let journal: (any AgentEventJournal)?
  public let gatewayConfiguration: GatewayConfiguration
  public let runtimeConfiguration: AgentRuntimeConfiguration
  public let inferenceProvider: any InferenceProvider
  public let toolExecutor: any ToolExecutor
  public let authorizationProvider: any AuthorizationProvider
  public let personalityContext: PersonalityContext?

  /// When present, the gateway ignores client-requested working directories and supplies this
  /// host-owned directory to every runtime tool execution context.
  public let enforcedWorkingDirectory: URL?

  public init(
    journalConfiguration: SQLiteAgentEventJournalConfiguration,
    inferenceProvider: any InferenceProvider,
    toolExecutor: any ToolExecutor,
    authorizationProvider: any AuthorizationProvider,
    gatewayConfiguration: GatewayConfiguration = .standard,
    runtimeConfiguration: AgentRuntimeConfiguration = AgentRuntimeConfiguration(),
    personalityContext: PersonalityContext? = nil,
    enforcedWorkingDirectory: URL? = nil
  ) {
    self.journalConfiguration = journalConfiguration
    journal = nil
    self.gatewayConfiguration = gatewayConfiguration
    self.runtimeConfiguration = runtimeConfiguration
    self.inferenceProvider = inferenceProvider
    self.toolExecutor = toolExecutor
    self.authorizationProvider = authorizationProvider
    self.personalityContext = personalityContext
    self.enforcedWorkingDirectory = enforcedWorkingDirectory
  }

  /// Creates a composition around a caller-owned durable journal. The composition does not close
  /// an injected journal; its owner retains lifecycle responsibility for that dependency.
  public init(
    journal: any AgentEventJournal,
    inferenceProvider: any InferenceProvider,
    toolExecutor: any ToolExecutor,
    authorizationProvider: any AuthorizationProvider,
    gatewayConfiguration: GatewayConfiguration = .standard,
    runtimeConfiguration: AgentRuntimeConfiguration = AgentRuntimeConfiguration(),
    personalityContext: PersonalityContext? = nil,
    enforcedWorkingDirectory: URL? = nil
  ) {
    journalConfiguration = nil
    self.journal = journal
    self.gatewayConfiguration = gatewayConfiguration
    self.runtimeConfiguration = runtimeConfiguration
    self.inferenceProvider = inferenceProvider
    self.toolExecutor = toolExecutor
    self.authorizationProvider = authorizationProvider
    self.personalityContext = personalityContext
    self.enforcedWorkingDirectory = enforcedWorkingDirectory
  }

  public static func inert(
    databaseURL: URL,
    gatewayConfiguration: GatewayConfiguration = .standard,
    runtimeConfiguration: AgentRuntimeConfiguration = AgentRuntimeConfiguration()
  ) -> Self {
    Self(
      journalConfiguration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL),
      inferenceProvider: HexGatewayInertInferenceProvider(),
      toolExecutor: HexGatewayInertToolExecutor(),
      authorizationProvider: CapabilityAuthorizationCenter(),
      gatewayConfiguration: gatewayConfiguration,
      runtimeConfiguration: runtimeConfiguration
    )
  }
}
