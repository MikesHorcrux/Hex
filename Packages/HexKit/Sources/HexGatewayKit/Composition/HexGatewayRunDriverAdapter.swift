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
  private let personalityContextService: PersonalityContextService?
  private let personalityMemoryQuery: PersonalMemoryQuery?
  private let enforcedModelID: ModelID?
  private let enforcedWorkingDirectory: URL?

  public init(
    inferenceProvider: any InferenceProvider,
    toolExecutor: any ToolExecutor,
    authorizationProvider: any AuthorizationProvider,
    journal: any AgentEventJournal,
    runtimeConfiguration: AgentRuntimeConfiguration = AgentRuntimeConfiguration(),
    personalityContext: PersonalityContext? = nil,
    personalityContextService: PersonalityContextService? = nil,
    personalityMemoryQuery: PersonalMemoryQuery? = nil,
    enforcedModelID: ModelID? = nil,
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
    self.personalityContextService = personalityContextService
    self.personalityMemoryQuery = personalityMemoryQuery
    self.enforcedModelID = enforcedModelID
    self.enforcedWorkingDirectory = enforcedWorkingDirectory
  }

  public func run(
    _ request: GatewayStartRunRequest,
    emit: @escaping @Sendable (AgentEventRecord) async throws -> Void
  ) async throws {
    try await journal.installEmitter(for: request.runID, emit: emit)

    do {
      let contextMessages: [Message]
      if let personalityContextService {
        guard let personalityMemoryQuery else {
          throw HexGatewayCompositionError.invalidPersonalityConfiguration
        }
        let context = try await personalityContextService.assemble(
          query: personalityMemoryQuery
        )
        contextMessages = context.messages
      } else {
        contextMessages = personalityMessages
      }

      let agentRequest = AgentRunRequest(
        runID: request.runID,
        modelID: enforcedModelID ?? request.modelID,
        initialMessages: request.initialMessages,
        contextMessages: contextMessages,
        options: request.options,
        toolChoice: request.toolChoice,
        // A resident host grants its configured workspace identity; an XPC client cannot replace it.
        workingDirectory: enforcedWorkingDirectory ?? request.workingDirectory
      )
      _ = try await runtime.run(agentRequest)
      await journal.removeEmitter(for: request.runID)
    } catch {
      await journal.removeEmitter(for: request.runID)
      throw error
    }
  }
}
