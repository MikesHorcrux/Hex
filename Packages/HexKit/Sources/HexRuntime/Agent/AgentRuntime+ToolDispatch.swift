import HexCore

extension AgentRuntime {
  func recordAnnouncedToolCalls(_ calls: [ToolCall], for runID: AgentRunID) throws {
    guard !calls.isEmpty else { return }
    var ledger = runToolDispatchLedgers[runID] ?? AgentToolDispatchLedger()
    try ledger.announce(calls)
    runToolDispatchLedgers[runID] = ledger
  }

  func recordToolStartAttempt(_ callID: ToolCallID, for runID: AgentRunID) throws {
    guard var ledger = runToolDispatchLedgers[runID] else {
      throw AgentRuntimeError.invalidState("A tool start has no native dispatch ledger.")
    }
    try ledger.markStartAttempted(callID)
    runToolDispatchLedgers[runID] = ledger
  }

  /// Keep execution and conversation facts together. The caller's cancellation cannot erase a
  /// known result, and a tool is settled only after the native result message is durably committed.
  func persistKnownToolReceipt(_ result: ToolResult, for runID: AgentRunID) async throws -> Message
  {
    guard var ledger = runToolDispatchLedgers[runID] else {
      throw AgentRuntimeError.invalidState("A known tool result has no native dispatch ledger.")
    }
    // A denied call has no start marker. Exclude it from synthetic cleanup before attempting either
    // receipt write, whose acknowledgement may fail after the journal has already committed it.
    try ledger.markReceiptAttempted(result.toolCallID)
    runToolDispatchLedgers[runID] = ledger
    let message = Message(role: .tool, content: [.toolResult(result)])
    try await appendKnownOutcome(.toolFinished(result), to: runID)
    try await appendKnownOutcome(.messageAppended(message), to: runID)
    guard var committedLedger = runToolDispatchLedgers[runID] else {
      throw AgentRuntimeError.invalidState("A known tool result has no native dispatch ledger.")
    }
    try committedLedger.markSettled(result.toolCallID)
    runToolDispatchLedgers[runID] = committedLedger
    return message
  }

  /// Never infer nonexecution from a thrown executor error or a missing completion record. A start
  /// attempt is excluded even if its journal acknowledgement failed: its commit may be ambiguous.
  func finishNeverStartedToolCalls(for runID: AgentRunID, reason: ToolNonExecutionReason)
    async throws
  {
    let pending = runToolDispatchLedgers[runID]?.neverStartedCalls ?? []
    for call in pending {
      let detail: String
      switch reason {
      case .cancelled:
        detail = "This tool was not run because the run was cancelled before it was dispatched."
      case .runStopped:
        detail = "This tool was not run because the run stopped before it was dispatched."
      case .interrupted:
        detail = "This tool was not run before the run was interrupted."
      case .authorizationDenied:
        detail = "This tool was not run because its authorization was denied."
      }
      let result = ToolResult(
        toolCallID: call.id, status: .failure,
        output: .object(["error": .string("not_executed"), "message": .string(detail)]),
        notExecutedReason: reason)
      _ = try await persistKnownToolReceipt(result, for: runID)
    }
  }
}
