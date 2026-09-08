import HexCore

struct SQLiteRunLifecycleValidator {
  private let runID: AgentRunID
  private var unresolvedToolCallSequences: [ToolCallID: UInt64] = [:]
  private var finishedToolCallIDs: Set<ToolCallID> = []
  private var authorizationRequestIDs: Set<AuthorizationRequestID> = []
  private var decidedAuthorizationRequestIDs: Set<AuthorizationRequestID> = []
  private var authorizationToolCallIDs: [AuthorizationRequestID: ToolCallID] = [:]
  private var correlatedToolStates: [ToolCallID: SQLiteAuthorizationCorrelatedToolState] = [:]
  private var hasRequestedInference = false
  private var hasStartedCompaction = false
  private var hasCompactedContext = false
  private var pendingContextCalls = Set<ToolCallID>()
  private var hasCompletedContextBatch = false
  private var nonExecution = SQLiteToolNonExecutionState()

  init(runID: AgentRunID) {
    self.runID = runID
  }

  var unresolvedToolCallIDs: [ToolCallID] {
    unresolvedToolCallSequences
      .sorted { left, right in left.value < right.value }
      .map(\.key)
  }

  var interruptedNonExecutionEvents: [AgentEvent] {
    nonExecution.recoveryEvents(
      started: Set(unresolvedToolCallSequences.keys), finished: finishedToolCallIDs)
  }

  mutating func consume(_ event: AgentEvent, sequence: UInt64) throws {
    switch event {
    case .contextCompactionStarted:
      guard !hasStartedCompaction || hasCompactedContext,
        hasRequestedInference ? hasCompletedContextBatch : !hasStartedCompaction,
        pendingContextCalls.isEmpty, unresolvedToolCallSequences.isEmpty
      else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "Context compaction requires a fresh turn or a completed tool batch.")
      }
      hasStartedCompaction = true
      hasCompactedContext = false
    case .contextCompacted(let compaction):
      guard compaction.ownerRunID == runID else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "A context compaction belongs to a different run.")
      }
      guard hasStartedCompaction, !hasCompactedContext,
        hasRequestedInference
          ? compaction.boundary == .completedToolBatch : compaction.boundary == nil
      else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "Context compaction must finish once at its declared boundary.")
      }
      hasCompactedContext = true
      hasCompletedContextBatch = false
    case .inferenceRequested:
      guard !hasStartedCompaction || hasCompactedContext else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "Inference cannot start before context compaction has a durable result.")
      }
      hasRequestedInference = true
      hasCompletedContextBatch = false
    case .messageAppended(let message):
      if hasRequestedInference {
        for content in message.content {
          switch content {
          case .toolCall(let call): pendingContextCalls.insert(call.id)
          case .toolResult(let result):
            guard pendingContextCalls.remove(result.toolCallID) != nil else {
              throw SQLiteAgentEventJournalError.corruptRecord("Unpaired context tool result.")
            }
            hasCompletedContextBatch = pendingContextCalls.isEmpty
          case .text, .image: break
          }
        }
        try nonExecution.consume(message)
      }
    case .authorizationRequested(let request):
      try consumeAuthorizationRequest(request)
    case .authorizationDecided(let requestID, let decision):
      try consumeAuthorizationDecision(requestID: requestID, decision: decision)
    case .toolStarted(let call):
      try consumeToolStart(call, sequence: sequence)
    case .toolFinished(let result):
      try consumeToolFinish(result)
    default:
      break
    }
  }

  func validateSuccessfulCompletion() throws {
    guard !hasStartedCompaction || hasCompactedContext else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "A completed run contains an unfinished context compaction.")
    }
    guard unresolvedToolCallSequences.isEmpty else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "A completed run contains an unresolved tool call."
      )
    }
    guard authorizationRequestIDs == decidedAuthorizationRequestIDs else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "A completed run contains an undecided authorization request."
      )
    }
    guard correlatedToolStates.values.allSatisfy({ $0 == .finished }) else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "A completed run contains an authorization-correlated tool without one durable outcome."
      )
    }
  }

  private mutating func consumeAuthorizationRequest(
    _ request: AuthorizationRequest
  ) throws {
    guard request.runID == runID else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "An authorization request belongs to a different run."
      )
    }
    guard authorizationRequestIDs.insert(request.id).inserted else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "A run contains a duplicate authorization request."
      )
    }
    guard let toolCallID = request.toolCallID else {
      return
    }
    guard
      correlatedToolStates[toolCallID] == nil,
      unresolvedToolCallSequences[toolCallID] == nil,
      !finishedToolCallIDs.contains(toolCallID)
    else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "A tool call is correlated with more than one lifecycle or authorization request."
      )
    }
    authorizationToolCallIDs[request.id] = toolCallID
    correlatedToolStates[toolCallID] = .requested
  }

  private mutating func consumeAuthorizationDecision(
    requestID: AuthorizationRequestID,
    decision: AuthorizationDecision
  ) throws {
    guard authorizationRequestIDs.contains(requestID) else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "An authorization decision has no preceding request."
      )
    }
    guard decidedAuthorizationRequestIDs.insert(requestID).inserted else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "A run contains a repeated authorization decision."
      )
    }
    guard let toolCallID = authorizationToolCallIDs[requestID] else {
      return
    }
    guard correlatedToolStates[toolCallID] == .requested else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "An authorization-correlated tool has contradictory durable ordering."
      )
    }
    switch decision {
    case .allow:
      correlatedToolStates[toolCallID] = .allowedAwaitingStart
    case .deny:
      correlatedToolStates[toolCallID] = .deniedAwaitingFailure
    }
  }

  private mutating func consumeToolStart(
    _ call: ToolCall,
    sequence: UInt64
  ) throws {
    if let state = correlatedToolStates[call.id] {
      guard state == .allowedAwaitingStart else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "An authorization-correlated tool start does not follow an allow decision."
        )
      }
      correlatedToolStates[call.id] = .allowedStarted
    }
    guard
      unresolvedToolCallSequences.updateValue(sequence, forKey: call.id) == nil,
      !finishedToolCallIDs.contains(call.id)
    else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "A run contains a duplicate or contradictory tool start."
      )
    }
  }

  private mutating func consumeToolFinish(_ result: ToolResult) throws {
    guard !finishedToolCallIDs.contains(result.toolCallID) else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "A run contains a repeated tool finish."
      )
    }

    if result.notExecutedReason != nil {
      try nonExecution.recordFinish(
        result, hasDurableStart: unresolvedToolCallSequences[result.toolCallID] != nil,
        authorizationState: correlatedToolStates[result.toolCallID])
      if correlatedToolStates[result.toolCallID] != nil {
        correlatedToolStates[result.toolCallID] = .finished
      }
      finishedToolCallIDs.insert(result.toolCallID)
      return
    }

    if let state = correlatedToolStates[result.toolCallID] {
      switch state {
      case .allowedStarted:
        guard unresolvedToolCallSequences.removeValue(forKey: result.toolCallID) != nil else {
          throw SQLiteAgentEventJournalError.corruptRecord(
            "An allowed tool finish has no preceding durable start."
          )
        }
      case .deniedAwaitingFailure:
        guard
          result.status == .failure,
          unresolvedToolCallSequences[result.toolCallID] == nil
        else {
          throw SQLiteAgentEventJournalError.corruptRecord(
            "A denied tool must finish exactly once with a failure and without starting."
          )
        }
      default:
        throw SQLiteAgentEventJournalError.corruptRecord(
          "An authorization-correlated tool finish has contradictory durable ordering."
        )
      }
      correlatedToolStates[result.toolCallID] = .finished
    } else {
      guard unresolvedToolCallSequences.removeValue(forKey: result.toolCallID) != nil else {
        throw SQLiteAgentEventJournalError.corruptRecord(
          "A tool finish has no unresolved start or prior authorization denial."
        )
      }
    }
    finishedToolCallIDs.insert(result.toolCallID)
  }
}
