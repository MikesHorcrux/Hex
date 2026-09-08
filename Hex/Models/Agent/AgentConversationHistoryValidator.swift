import HexCore

nonisolated enum AgentConversationHistoryValidator {
  private static let maximumMessages = 4_096
  private static let maximumExchanges = 512

  static func validate(
    _ history: AgentConversationHistory, runIDs: inout Set<AgentRunID>
  ) throws {
    guard history.exchanges.count <= maximumExchanges,
      history.legacyMessages.count <= maximumMessages
    else { throw invalid("Structured conversation history exceeds its record limits.") }
    var messageCount = history.legacyMessages.count
    var messagesByID: [MessageID: Message] = [:]
    for message in history.legacyMessages {
      guard message.role == .user || message.role == .assistant,
        message.content.allSatisfy({
          if case .text = $0 { return true }
          return false
        }),
        messagesByID.updateValue(message, forKey: message.id) == nil
      else {
        throw invalid("Legacy history must contain uniquely identified user/assistant text only.")
      }
      try AgentConversationPayloadValidator.validate(message)
    }

    var priorExchanges: [AgentRunID: AgentConversationExchange] = [:]
    var retriedRunIDs = Set<AgentRunID>()
    for exchange in history.exchanges {
      guard runIDs.insert(exchange.runID).inserted,
        !exchange.messages.isEmpty,
        exchange.messages.count <= maximumMessages - messageCount,
        exchange.messages.first?.role == .user,
        exchange.lastEventSequence.map({ $0 > 0 }) ?? true
      else { throw invalid("A native exchange has invalid identity, messages, or event sequence.") }
      messageCount += exchange.messages.count
      let reusedUserID = try validateRetry(
        exchange, priorExchanges: priorExchanges, retriedRunIDs: &retriedRunIDs)
      var callIDs = Set<ToolCallID>()
      var pendingCallIDs = Set<ToolCallID>()

      for (index, message) in exchange.messages.enumerated() {
        if index > 0 {
          guard message.role == .assistant || message.role == .tool else {
            throw invalid("A native exchange contains repeated request context or an invalid role.")
          }
        }
        if let existing = messagesByID[message.id] {
          guard index == 0, reusedUserID == message.id, existing == message else {
            throw invalid("Native message identities are duplicated outside an explicit retry.")
          }
        } else {
          messagesByID[message.id] = message
        }
        try AgentConversationPayloadValidator.validate(message)
        if message.role == .assistant, !pendingCallIDs.isEmpty {
          throw invalid("An assistant message precedes required tool results.")
        }
        for content in message.content {
          switch content {
          case .toolCall(let call):
            guard callIDs.insert(call.id).inserted else {
              throw invalid("A native exchange repeats a tool call identity.")
            }
            pendingCallIDs.insert(call.id)
          case .toolResult(let result):
            guard pendingCallIDs.remove(result.toolCallID) != nil else {
              throw invalid("A native tool result has no unique preceding call.")
            }
          case .text, .image:
            break
          }
        }
      }
      guard exchange.outcome != .completed || pendingCallIDs.isEmpty else {
        throw invalid("A completed exchange contains unresolved tool calls.")
      }
      priorExchanges[exchange.runID] = exchange
    }
    _ = try AgentConversationContextProjection.messages(in: history)
  }

  private static func validateRetry(
    _ exchange: AgentConversationExchange,
    priorExchanges: [AgentRunID: AgentConversationExchange],
    retriedRunIDs: inout Set<AgentRunID>
  ) throws -> MessageID? {
    guard let retryOfRunID = exchange.retryOfRunID else { return nil }
    guard let previous = priorExchanges[retryOfRunID],
      [.failed, .cancelled, .interrupted].contains(previous.outcome),
      previous.messages.first == exchange.messages.first,
      retriedRunIDs.insert(retryOfRunID).inserted,
      previous.messages.allSatisfy({ message in
        message.content.allSatisfy { content in
          switch content {
          case .toolCall, .toolResult: return false
          case .text, .image: return true
          }
        }
      })
    else { throw invalid("A retry does not reference one earlier terminal, tool-free attempt.") }
    return previous.messages.first?.id
  }

  private static func invalid(_ reason: String) -> AgentConversationStoreError {
    .invalidArchive(reason)
  }
}
