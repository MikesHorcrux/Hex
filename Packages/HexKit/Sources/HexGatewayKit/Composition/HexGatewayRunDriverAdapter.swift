import Foundation
import HexCore
import HexIPC
import HexPersonality
import HexRuntime

/// Adapts the process-neutral gateway request to the agent runtime while publishing each durable
/// journal record through the gateway service callback.
public struct HexGatewayRunDriverAdapter: HexGatewayRunDriver, Sendable {
  public let runtime: AgentRuntime

  private let journal: HexGatewayEventJournal
  private let personalityMessages: [Message]
  private let enforcedWorkingDirectory: URL?

  public init(
    inferenceProvider: any InferenceProvider,
    toolExecutor: any ToolExecutor,
    authorizationProvider: any AuthorizationProvider,
    journal: any AgentEventJournal,
    runtimeConfiguration: AgentRuntimeConfiguration = AgentRuntimeConfiguration(),
    personalityContext: PersonalityContext? = nil,
    enforcedWorkingDirectory: URL? = nil
  ) {
    let eventJournal = HexGatewayEventJournal(base: journal)
    self.journal = eventJournal
    self.runtime = AgentRuntime(
      inferenceProvider: inferenceProvider,
      toolExecutor: toolExecutor,
      authorizationProvider: authorizationProvider,
      journal: eventJournal,
      configuration: runtimeConfiguration
    )
    personalityMessages = personalityContext?.messages ?? []
    self.enforcedWorkingDirectory = enforcedWorkingDirectory
  }

  public func run(
    _ request: GatewayStartRunRequest,
    emit: @escaping @Sendable (AgentEventRecord) async throws -> Void
  ) async throws {
    try await journal.installEmitter(for: request.runID, emit: emit)
    let agentRequest = AgentRunRequest(
      runID: request.runID,
      modelID: request.modelID,
      initialMessages: personalityMessages + request.initialMessages,
      options: request.options,
      toolChoice: request.toolChoice,
      // A resident host grants its configured workspace identity; an XPC client cannot replace it.
      workingDirectory: enforcedWorkingDirectory ?? request.workingDirectory
    )

    do {
      _ = try await runtime.run(agentRequest)
      await journal.removeEmitter(for: request.runID)
    } catch {
      await journal.removeEmitter(for: request.runID)
      throw error
    }
  }
}
