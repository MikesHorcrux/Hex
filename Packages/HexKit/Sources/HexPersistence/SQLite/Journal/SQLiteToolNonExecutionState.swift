import HexCore

/// New host-issued non-execution facts require native declaration proof. Legacy lifecycle events
/// remain valid without declarations; initial messages are deliberately excluded by the caller.
struct SQLiteToolNonExecutionState {
  private var declarations: [ToolCallID] = []
  private var declarationCounts: [ToolCallID: Int] = [:]
  private var markedResults: [ToolCallID: ToolResult] = [:]
  private var markedResultOrder: [ToolCallID] = []
  private var projectedResults: Set<ToolCallID> = []
  private var unmarkedNativeResults: Set<ToolCallID> = []

  mutating func consume(_ message: Message) throws {
    for part in message.content {
      switch part {
      case .toolCall(let call) where message.role == .assistant:
        if declarationCounts[call.id] == nil { declarations.append(call.id) }
        declarationCounts[call.id, default: 0] += 1
      case .toolResult(let result):
        guard result.notExecutedReason != nil || markedResults[result.toolCallID] != nil else {
          unmarkedNativeResults.insert(result.toolCallID)
          continue
        }
        guard message.role == .tool, markedResults[result.toolCallID] == result,
          projectedResults.insert(result.toolCallID).inserted
        else {
          throw SQLiteAgentEventJournalError.corruptRecord(
            "A non-execution native receipt must exactly match one preceding durable finish.")
        }
      default: break
      }
    }
  }

  mutating func recordFinish(
    _ result: ToolResult, hasDurableStart: Bool,
    authorizationState: SQLiteAuthorizationCorrelatedToolState?
  ) throws {
    guard declarationCounts[result.toolCallID] == 1, !hasDurableStart,
      !unmarkedNativeResults.contains(result.toolCallID),
      result.hasValidNonExecutionMetadata, markedResults[result.toolCallID] == nil
    else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "A non-execution receipt requires one current-run declaration and no durable tool start or output."
      )
    }
    switch authorizationState {
    case nil, .requested, .allowedAwaitingStart, .deniedAwaitingFailure: break
    default:
      throw SQLiteAgentEventJournalError.corruptRecord(
        "A non-execution receipt contradicts the durable authorization or execution state.")
    }
    if result.notExecutedReason == .authorizationDenied,
      authorizationState != .deniedAwaitingFailure
    {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "An authorization-denied receipt requires a preceding durable deny decision.")
    }
    markedResults[result.toolCallID] = result
    markedResultOrder.append(result.toolCallID)
  }

  func recoveryEvents(started: Set<ToolCallID>, finished: Set<ToolCallID>) -> [AgentEvent] {
    // First repair the crash boundary between an already committed marked finish and its native
    // receipt. Reuse the exact stored result; never convert a started call into "not executed".
    var events = markedResultOrder.compactMap { callID -> AgentEvent? in
      guard !projectedResults.contains(callID), let result = markedResults[callID] else {
        return nil
      }
      return .messageAppended(Message(role: .tool, content: [.toolResult(result)]))
    }
    for callID in declarations {
      guard declarationCounts[callID] == 1, !started.contains(callID),
        !finished.contains(callID)
          && !unmarkedNativeResults.contains(callID)
      else { continue }
      let result = ToolResult(
        toolCallID: callID, status: .failure,
        output: .object([
          "message": .string(
            "Hex was interrupted before this tool call started. The tool was not executed.")
        ]), notExecutedReason: .interrupted)
      events.append(.toolFinished(result))
      events.append(.messageAppended(Message(role: .tool, content: [.toolResult(result)])))
    }
    return events
  }
}
