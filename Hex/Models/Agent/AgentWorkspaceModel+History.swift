import HexCore
import HexIPC

extension AgentWorkspaceModel {
  func captureHistoryCompaction(_ compaction: AgentContextCompaction) throws {
    guard let request = currentRunRequest,
      compaction.ownerRunID == request.runID,
      compaction.modelID == request.modelID,
      compaction.boundary == .completedToolBatch
        || (compaction.sourceMessageIDs.count < request.initialMessages.count
          && Array(request.initialMessages.prefix(compaction.sourceMessageIDs.count).map(\.id))
            == compaction.sourceMessageIDs),
      let index = conversations.firstIndex(where: { $0.id == selectedConversationID }),
      var history = conversations[index].history
    else {
      throw GatewayFailure(
        code: .malformedPayload,
        message: "The context summary does not match the current conversation request.")
    }
    if let existing = history.compactions.first(where: { $0.id == compaction.id }) {
      guard existing == compaction else {
        throw GatewayFailure(
          code: .malformedPayload,
          message: "The gateway changed a previously received context summary.")
      }
      return
    }
    history.compactions.append(compaction)
    do {
      _ = try AgentConversationContextProjection.messages(in: history)
    } catch {
      throw GatewayFailure(
        code: .malformedPayload,
        message: "The context summary could not be matched to preserved history.")
    }
    conversations[index].history = history
    persistConversationArchive()
  }

  func beginHistoryExchange(runID: AgentRunID, userMessage: Message) {
    guard let index = conversations.firstIndex(where: { $0.id == selectedConversationID }) else {
      return
    }
    var history = conversations[index].resolvedHistory()
    history.exchanges.append(AgentConversationExchange(runID: runID, messages: [userMessage]))
    conversations[index].history = history
  }

  func beginRetryExchange(_ request: GatewayStartRunRequest, retryOf runID: AgentRunID) -> Bool {
    guard let index = conversations.firstIndex(where: { $0.id == selectedConversationID }),
      let userMessage = request.initialMessages.last, userMessage.role == .user
    else { return false }
    var candidate = conversations[index]
    var history = candidate.resolvedHistory()
    history.exchanges.append(
      AgentConversationExchange(
        runID: request.runID, messages: [userMessage], retryOfRunID: runID))
    candidate.history = history
    candidate.transcript = transcript
    guard validateConversationAdmission(candidate) else { return false }
    conversations[index] = candidate
    return true
  }

  /// Capture provider-native data before deriving any display text. Identical replay is harmless;
  /// changing the content behind an already-observed ID is a protocol failure, not a new message.
  func captureHistoryMessage(_ message: Message) throws -> Bool {
    if pendingInitialMessageIDs.contains(message.id) {
      guard currentRunRequest?.initialMessages.first(where: { $0.id == message.id }) == message
      else {
        throw GatewayFailure(
          code: .malformedPayload,
          message: "The gateway changed the original request context while replaying it.")
      }
      return false
    }
    guard message.role == .assistant || message.role == .tool else {
      throw GatewayFailure(
        code: .malformedPayload,
        message: "The gateway returned an unexpected message role outside the request context.")
    }
    guard let index = conversations.firstIndex(where: { $0.id == selectedConversationID }),
      var history = conversations[index].history,
      let exchangeIndex = history.exchanges.firstIndex(where: { $0.runID == currentRunID })
    else { return true }
    if let prior = history.legacyMessages.first(where: { $0.id == message.id })
      ?? history.exchanges.flatMap(\.messages).first(where: { $0.id == message.id })
    {
      guard prior == message else {
        throw GatewayFailure(
          code: .malformedPayload,
          message: "The gateway changed a message that had already been received.")
      }
      return false
    }
    history.exchanges[exchangeIndex].messages.append(message)
    conversations[index].history = history
    if message.content.contains(where: {
      if case .toolCall = $0 { return true }
      if case .toolResult = $0 { return true }
      return false
    }) {
      currentRunHasToolEvidence = true
    }
    return true
  }

  func updateHistoryOutcome(_ outcome: AgentConversationExchange.Outcome) {
    guard let index = conversations.firstIndex(where: { $0.id == selectedConversationID }),
      var history = conversations[index].history,
      let exchangeIndex = history.exchanges.firstIndex(where: { $0.runID == currentRunID })
    else { return }
    history.exchanges[exchangeIndex].outcome = outcome
    conversations[index].history = history
    persistConversationArchive()
  }

  func updateHistorySequence(_ sequence: UInt64) {
    guard let index = conversations.firstIndex(where: { $0.id == selectedConversationID }),
      var history = conversations[index].history,
      let exchangeIndex = history.exchanges.firstIndex(where: { $0.runID == currentRunID })
    else { return }
    history.exchanges[exchangeIndex].lastEventSequence = sequence
    conversations[index].history = history
    // This is a projection watermark, not a durable gateway acknowledgement. Reattachment across
    // process restart requires the saved request/invocation and a transactional checkpoint.
  }
}
