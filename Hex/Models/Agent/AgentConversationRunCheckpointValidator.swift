import Foundation
import HexCore
import HexIPC

nonisolated enum AgentConversationRunCheckpointValidator {
  nonisolated static func validate(
    _ checkpoint: AgentConversationRunCheckpoint, in conversation: AgentConversation
  ) throws {
    guard let history = conversation.history, let exchange = history.exchanges.last,
      exchange.runID == checkpoint.request.runID,
      exchange.outcome == .inProgress || exchange.outcome == .interrupted,
      !isZero(checkpoint.request.runID.rawValue),
      checkpoint.appliedSequence < UInt64.max,
      (exchange.lastEventSequence ?? 0) == checkpoint.appliedSequence,
      checkpoint.request.initialMessages
        == (try history.initialRequestMessages(for: exchange.runID))
    else {
      throw invalid("The pending request does not match its exact native history checkpoint.")
    }
    try validateRequest(checkpoint.request)
    // Older requests omitted this sidecar. Keep their exact admitted payload unchanged during
    // read-only recovery; deriving new grants here would change request identity after dispatch.
    if !checkpoint.request.availableArtifacts.isEmpty {
      guard
        checkpoint.request.availableArtifacts
          == (try conversation.availableArtifacts(before: checkpoint.request.runID))
      else {
        throw invalid("The pending request's saved-output inventory changed after admission.")
      }
    }
    do { try ToolArtifactValidation.validate(checkpoint.request.availableArtifacts) } catch {
      throw invalid("The pending request's saved-output inventory is invalid.")
    }
    try validateIdentity(checkpoint)
    try validatePartialRow(checkpoint, transcript: conversation.transcript)
    try validateApprovals(checkpoint, exchange: exchange)
    if checkpoint.appliedSequence == 0 {
      guard exchange.messages.count == 1, checkpoint.streamingAssistantItemID == nil,
        checkpoint.pendingAuthorizations.isEmpty, !checkpoint.hasToolEvidence,
        !history.compactions.contains(where: { $0.ownerRunID == exchange.runID })
      else { throw invalid("An unobserved run checkpoint contains generated event state.") }
    }
  }

  private nonisolated static func validateRequest(_ request: GatewayStartRunRequest) throws {
    guard !request.initialMessages.isEmpty, request.initialMessages.count <= 4_096,
      !request.modelID.rawValue.isEmpty, request.modelID.rawValue.utf8.count <= 512,
      request.modelID.rawValue
        == request.modelID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
      !request.modelID.rawValue.contains("\0"),
      request.options.maxOutputTokens.map({ $0 > 0 }) ?? true,
      request.options.temperature.map(\.isFinite) ?? true
    else { throw invalid("A pending inference request has invalid options or model identity.") }
    if case .named(let name) = request.toolChoice {
      try validateIdentifier(name, maximumBytes: 128)
    }
    if let directory = request.workingDirectory {
      guard directory.isFileURL, directory.path.hasPrefix("/"),
        directory.path.utf8.count <= 4_096, !directory.path.contains("\0"),
        directory.user == nil, directory.password == nil
      else { throw invalid("A pending request has an invalid workspace reference.") }
    }
    for message in request.initialMessages {
      try AgentConversationPayloadValidator.validate(message)
    }
  }

  private nonisolated static func validateIdentity(_ checkpoint: AgentConversationRunCheckpoint)
    throws
  {
    guard (checkpoint.gatewayInstanceID == nil) == (checkpoint.invocationID == nil),
      checkpoint.gatewayInstanceID.map({ !isZero($0.rawValue) }) ?? true,
      checkpoint.invocationID.map({ !isZero($0.rawValue) }) ?? true,
      checkpoint.firstEventID.map({ !isZero($0.rawValue) }) ?? true,
      (checkpoint.appliedSequence == 0) == (checkpoint.firstEventID == nil)
    else {
      throw invalid("A pending run has inconsistent invocation or journal-anchor identities.")
    }
  }

  private nonisolated static func validatePartialRow(
    _ checkpoint: AgentConversationRunCheckpoint, transcript: [ConversationItem]
  ) throws {
    guard Set(transcript.map(\.id)).count == transcript.count,
      transcript.filter(\.isStreaming).allSatisfy({ $0.id == checkpoint.streamingAssistantItemID })
    else { throw invalid("The pending transcript has duplicate or untracked streaming rows.") }
    if let id = checkpoint.streamingAssistantItemID {
      guard !isZero(id), let row = transcript.first(where: { $0.id == id }), row.role == .assistant
      else {
        throw invalid("The pending assistant row does not match the saved transcript.")
      }
    }
  }

  private nonisolated static func validateApprovals(
    _ checkpoint: AgentConversationRunCheckpoint, exchange: AgentConversationExchange
  ) throws {
    guard checkpoint.pendingAuthorizations.count <= 128 else {
      throw invalid("The pending approval queue exceeds its record limit.")
    }
    var pendingCallIDs = Set<ToolCallID>()
    var hasNativeToolEvidence = false
    for content in exchange.messages.flatMap(\.content) {
      switch content {
      case .toolCall(let call):
        hasNativeToolEvidence = true
        pendingCallIDs.insert(call.id)
      case .toolResult(let result):
        hasNativeToolEvidence = true
        pendingCallIDs.remove(result.toolCallID)
      case .text, .image: break
      }
    }
    guard checkpoint.hasToolEvidence || !hasNativeToolEvidence else {
      throw invalid("The pending checkpoint omits observed tool evidence.")
    }
    var requestIDs = Set<AuthorizationRequestID>()
    var approvalToolIDs = Set<ToolCallID>()
    for request in checkpoint.pendingAuthorizations {
      guard request.runID == exchange.runID, !isZero(request.id.rawValue),
        requestIDs.insert(request.id).inserted,
        !request.operation.isEmpty, request.operation.utf8.count <= 4_096,
        request.explanation.utf8.count <= 64 * 1_024,
        request.resource.map({ $0.utf8.count <= 8_192 && !$0.contains("\0") }) ?? true,
        !request.operation.contains("\0"), !request.explanation.contains("\0")
      else { throw invalid("A pending approval has invalid identity or description.") }
      try validateIdentifier(request.capability.rawValue, maximumBytes: 256)
      if let callID = request.toolCallID {
        guard checkpoint.hasToolEvidence, pendingCallIDs.contains(callID),
          approvalToolIDs.insert(callID).inserted
        else {
          throw invalid("A pending approval does not identify one unresolved native tool call.")
        }
      }
      // Reuse the established JSON size/depth checks without resolving or acting on this data.
      try AgentConversationPayloadValidator.validate(
        Message(
          role: .assistant,
          content: [
            .toolCall(
              ToolCall(
                id: ToolCallID(rawValue: "approval_details"), name: "approval",
                arguments: request.details))
          ]))
      guard try JSONEncoder().encode(request).count <= 1_024 * 1_024 else {
        throw invalid("A pending approval exceeds its payload limit.")
      }
    }
  }

  private nonisolated static func validateIdentifier(_ value: String, maximumBytes: Int) throws {
    guard !value.isEmpty, value.utf8.count <= maximumBytes,
      value.utf8.allSatisfy({ (0x21...0x7E).contains($0) })
    else { throw invalid("A pending request contains an invalid capability or tool name.") }
  }

  private nonisolated static func isZero(_ value: UUID) -> Bool {
    value.uuidString == "00000000-0000-0000-0000-000000000000"
  }

  private nonisolated static func invalid(_ reason: String) -> AgentConversationStoreError {
    .invalidArchive(reason)
  }
}
