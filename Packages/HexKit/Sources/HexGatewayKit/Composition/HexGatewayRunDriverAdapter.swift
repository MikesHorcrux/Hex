import Foundation
import HexCore
import HexIPC
import HexPersonality
import HexRuntime

/// Adapts the process-neutral gateway request to the agent runtime while publishing each durable
/// journal record through the gateway service callback.
public struct HexGatewayRunDriverAdapter: HexGatewayRunDriver, Sendable {
  public let runtime: AgentRuntime

  private let taskToolExecutor: HexTaskGuardedToolExecutor
  private let journal: HexGatewayEventJournal
  private let operatingContractMessage: Message
  private let personalityMessages: [Message]
  private let personalityContextService: PersonalityContextService?
  private let personalityMemoryQuery: PersonalMemoryQuery?
  private let enforcedModelID: ModelID?
  private let enforcedWorkingDirectory: URL?
  private let selfKnowledgeService: HexSelfKnowledgeService

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
    enforcedWorkingDirectory: URL? = nil,
    selfKnowledge: HexSelfKnowledge = HexSelfKnowledge(),
    artifactWriter: (any ArtifactWriting)? = nil
  ) {
    let eventJournal = HexGatewayEventJournal(base: journal)
    self.journal = eventJournal
    let selfKnowledgeService = HexSelfKnowledgeService(
      knowledge: selfKnowledge, provider: inferenceProvider.descriptor
    )
    self.selfKnowledgeService = selfKnowledgeService
    let taskToolExecutor = HexTaskGuardedToolExecutor(
      base: toolExecutor, effects: journal as? any AgentTaskEffectReading)
    self.taskToolExecutor = taskToolExecutor
    self.runtime = AgentRuntime(
      inferenceProvider: inferenceProvider,
      toolExecutor: HexSelfInspectionToolExecutor(
        service: selfKnowledgeService,
        base: taskToolExecutor),
      authorizationProvider: authorizationProvider,
      journal: eventJournal,
      configuration: runtimeConfiguration,
      contextEstimator: ConservativeAgentContextTokenEstimator(
        imageTokenUpperBounds: HexGatewayImageTokenBounds.documented),
      artifactWriter: artifactWriter
    )
    operatingContractMessage = HexAgentOperatingContract().message
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
      let modelID = enforcedModelID ?? request.modelID
      let workingDirectory = enforcedWorkingDirectory ?? request.workingDirectory
      let selfMessage = try await selfKnowledgeService.beginRun(
        runID: request.runID,
        modelID: modelID,
        workingDirectory: workingDirectory,
        options: request.options
      )
      // The operating contract is stable Hex identity. The detailed self snapshot remains
      // available through hex_inspect_self and is injected only for requests that are actually
      // about Hex's runtime/provider/settings. This keeps normal conversation model-light while
      // preserving an explicit self-diagnosis path.
      let coreMessages =
        [operatingContractMessage]
        + (Self.shouldInlineSelfKnowledge(in: request.initialMessages) ? [selfMessage] : [])
      let contextMessages: [Message]
      if let personalityContextService {
        guard let personalityMemoryQuery else {
          throw HexGatewayCompositionError.invalidPersonalityConfiguration
        }
        do {
          let context = try await personalityContextService.assemble(
            query: personalityMemoryQuery
          )
          contextMessages = coreMessages + context.messages
        } catch PersonalityContextServiceError.profileUnavailable {
          // Personality setup is optional. A profile that has never been created must not prevent
          // the core agent runtime from starting; malformed persisted data still fails closed.
          contextMessages = coreMessages
        }
      } else {
        contextMessages = coreMessages + personalityMessages
      }

      let agentRequest = AgentRunRequest(
        runID: request.runID,
        modelID: modelID,
        initialMessages: request.initialMessages,
        contextMessages: contextMessages,
        options: request.options,
        toolChoice: request.toolChoice,
        // A resident host grants its configured workspace identity; an XPC client cannot replace it.
        workingDirectory: workingDirectory,
        availableArtifacts: request.availableArtifacts,
        authorizationMode: request.authorizationMode
      )
      _ = try await runtime.run(agentRequest)
      await taskToolExecutor.finishRun(request.runID)
      await selfKnowledgeService.endRun(request.runID)
      await journal.removeEmitter(for: request.runID)
    } catch let error as AgentRuntimeError {
      await taskToolExecutor.finishRun(request.runID)
      await selfKnowledgeService.endRun(request.runID)
      await journal.removeEmitter(for: request.runID)
      throw HexGatewayRunFailureMapper.map(error)
    } catch {
      await taskToolExecutor.finishRun(request.runID)
      await selfKnowledgeService.endRun(request.runID)
      await journal.removeEmitter(for: request.runID)
      throw error
    }
  }

  private static func shouldInlineSelfKnowledge(in messages: [Message]) -> Bool {
    let text =
      messages
      .filter { $0.role == .user }
      .flatMap { message in
        message.content.compactMap { content in
          if case .text(let value) = content { return value }
          return nil
        }
      }
      .joined(separator: " ")
      .lowercased()
    let terms = Set(
      text.split { character in
        !(character.isLetter || character.isNumber || character == "_")
      }.map(String.init)
    )
    let selfTerms: Set<String> = [
      "backend", "gateway", "hex", "inference", "model", "provider", "runtime", "settings",
      "start", "stop", "broken", "crash", "debug", "install", "download",
    ]
    return !terms.isDisjoint(with: selfTerms)
  }
}
