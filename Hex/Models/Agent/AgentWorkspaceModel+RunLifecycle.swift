import Foundation
import HexCore
import HexIPC

extension AgentWorkspaceModel {
  func startRun(_ request: GatewayStartRunRequest) async {
    let runID = request.runID
    let conversationID = selectedConversationID
    var receivedTerminalEvent = false
    var shouldRecoverDelivery = false
    defer {
      if currentRunID == runID, selectedConversationID == conversationID {
        runTask = nil
        if shouldRecoverDelivery, let conversationID {
          scheduleAutomaticDeliveryRecovery(request, conversationID: conversationID)
        }
      }
    }

    do {
      let response: GatewayStartRunResponse
      do {
        response = try await client.startRun(request)
      } catch let failure as GatewayFailure where failure.code == .toolMaintenanceInProgress {
        try Task.checkCancellation()
        guard currentRunID == runID else { return }
        // This is a typed non-admission receipt, not a lost response or an uncertain tool outcome.
        runState = .failed
        isFailedRunRetryAvailable = true
        retryRequiresFreshRunID = true
        needsRunRecovery = false
        updateHistoryOutcome(.failed)
        activity = "Task not started while Hex checks a tool connection."
        errorMessage =
          "Hex is checking a tool connection. Your request has not started. Retry after the check finishes."
        return
      }
      guard currentRunID == runID else { return }

      let invocationID: GatewayRunInvocationID
      switch response.disposition {
      case .started(let admittedInvocationID),
        .alreadyRunning(let admittedInvocationID),
        .alreadyTerminal(let admittedInvocationID):
        invocationID = admittedInvocationID
      case .busy(let activeRunID):
        runState = .failed
        isFailedRunRetryAvailable = true
        // This is an explicit non-admission response, unlike a lost transport acknowledgement.
        retryRequiresFreshRunID = true
        needsRunRecovery = false
        updateHistoryOutcome(.failed)
        activity = "Run admission blocked."
        errorMessage =
          "Another run is active (\(shortID(for: activeRunID))). Wait for it to finish or cancel it, then retry."
        return
      }

      currentInvocationID = invocationID
      currentRunGatewayInstanceID = connectedGatewayInstanceID
      if case .alreadyTerminal = response.disposition {
        runState = .running
        activity = "Showing the remembered terminal run."
      } else {
        runState = .running
        activity = "Streaming from the gateway…"
      }

      let stream = try await client.eventRecords(for: runID, invocationID: invocationID)
      for try await envelope in stream {
        guard currentRunID == runID else { return }
        guard try await client.shouldApply(envelope) else { continue }
        try reduceRunRecord(envelope.record)
        receivedTerminalEvent = isTerminalRunEvent(envelope.record.event)
        try await client.acknowledge(envelope)
      }
      guard receivedTerminalEvent else {
        throw GatewayFailure(
          code: .producerEndedWithoutTerminalEvent,
          message: "The event stream ended before the run outcome was known.", isRetryable: true)
      }
    } catch is CancellationError {
      guard currentRunID == runID else { return }
      if !receivedTerminalEvent {
        runState = .failed
        isFailedRunRetryAvailable = true
        retryRequiresFreshRunID = false
        activity = "Run observation interrupted; the gateway outcome is not yet known."
        needsRunRecovery = true
        pauseStreamingAssistant()
        updateHistoryOutcome(.interrupted)
      }
    } catch {
      guard currentRunID == runID else { return }
      if let failure = error as? GatewayFailure {
        switch failure.code {
        case .notConnected, .staleSession, .transportUnavailable, .disconnected,
          .producerEndedWithoutTerminalEvent:
          markGatewayDisconnected()
        default: break
        }
      }
      // A transport/acknowledgement error after a durable terminal event cannot rewrite its outcome.
      guard !receivedTerminalEvent else { return }
      runState = .failed
      isFailedRunRetryAvailable = (error as? GatewayFailure)?.isRetryable ?? true
      retryRequiresFreshRunID = false
      needsRunRecovery = true
      activity = "Run stopped."
      pauseStreamingAssistant()
      updateHistoryOutcome(.interrupted)
      errorMessage = actionableMessage(
        for: error,
        context: "The gateway could not complete the run"
      )
      shouldRecoverDelivery = isAutomaticallyRecoverableDeliveryFailure(error)
    }

  }

  func reduceRunRecord(_ record: AgentEventRecord) throws {
    guard record.runID == currentRunID, currentAppliedSequence < UInt64.max,
      record.sequence == currentAppliedSequence + 1
    else {
      throw GatewayFailure(
        code: .invalidEventSequence,
        message: "Recovered run history does not match the saved checkpoint.")
    }
    isReducingRunEvent = true
    defer { isReducingRunEvent = false }
    try apply(record)
    if record.sequence == 1 { currentFirstEventID = record.id }
    currentAppliedSequence = record.sequence
    updateHistorySequence(record.sequence)
    isReducingRunEvent = false
    scheduleRunCheckpoint(for: record.event)
  }

  func isTerminalRunEvent(_ event: AgentEvent) -> Bool {
    switch event {
    case .runCompleted, .runCancelled, .runFailed: true
    default: false
    }
  }

  private func apply(_ record: AgentEventRecord) throws {
    switch record.event {
    case .runStarted:
      runState = .running
      activity = "Agent started."

    case .messageAppended(let message):
      if try captureHistoryMessage(message) { append(message) }

    case .contextCompactionStarted:
      activity = "Condensing earlier conversation…"
      appendEvent("Condensing earlier conversation; original messages will be preserved.")

    case .contextCompacted(let compaction):
      try captureHistoryCompaction(compaction)
      activity = "Earlier conversation condensed."
      let usage: String
      if let tokens = compaction.reportedTokens, let calls = compaction.inferenceCalls {
        usage = "Summary work: \(calls) inference calls · \(tokens) reported tokens."
      } else {
        usage = "Summary usage unavailable."
      }
      appendEvent(
        "Earlier conversation summarized. Original messages are preserved locally. \(usage)")

    case .inferenceRequested(let request):
      activity = "Thinking with \(request.modelID.rawValue)…"

    case .inferenceEvent(let event):
      applyInferenceEvent(event)

    case .authorizationRequested(let request):
      guard request.runID == currentRunID else {
        throw GatewayFailure(code: .malformedPayload, message: "Approval belongs to another run.")
      }
      if let existing = pendingAuthorizations.first(where: { $0.id == request.id }) {
        guard existing == request else {
          throw GatewayFailure(
            code: .malformedPayload, message: "An approval changed after being requested.")
        }
        return
      }
      guard pendingAuthorizations.count < 128 else {
        throw GatewayFailure(code: .malformedPayload, message: "Too many unresolved approvals.")
      }
      pendingAuthorizations.append(request)
      runState = .waitingForAuthorization
      let resource = request.resource.map { " · \($0)" } ?? ""
      activity = "Approval needed for \(request.operation)\(resource)."
      appendEvent("Approval requested · \(request.capability.rawValue)")

    case .authorizationDecided(let requestID, let decision):
      guard pendingAuthorizations.contains(where: { $0.id == requestID }) else { return }
      retireAuthorizations([requestID])
      switch decision {
      case .allow:
        activity = "Approval granted."
        appendEvent("Approval granted")
      case .deny(let reason):
        activity = "Approval denied."
        appendEvent(reason.map { "Approval denied · \($0)" } ?? "Approval denied")
      }

    case .toolStarted(let call):
      currentRunHasToolEvidence = true
      activity = "Running \(call.name)…"
      appendTool("Started \(call.name)")

    case .toolFinished(let result):
      guard result.hasValidNonExecutionMetadata else {
        throw GatewayFailure(
          code: .malformedPayload,
          message: "A tool result contains contradictory execution evidence.")
      }
      try captureArtifactInventory(result)
      if result.notExecutedReason != nil {
        // The action is durably closed, not approved. Retire only its obsolete requests before
        // the following native result can be checkpointed; unrelated approvals remain pending.
        retireAuthorizations(
          Set(pendingAuthorizations.filter { $0.toolCallID == result.toolCallID }.map(\.id)))
      }
      currentRunHasToolEvidence = true
      activity =
        result.notExecutedReason != nil
        ? "Tool was not run." : (result.status == .success ? "Tool finished." : "Tool failed.")
      appendTool(toolResultText(result), artifacts: result.artifacts, toolCallID: result.toolCallID)

    case .runCompleted:
      resetAuthorizations()
      runState = .completed
      currentRunRequest = nil
      isFailedRunRetryAvailable = false
      retryRequiresFreshRunID = false
      activity = "Completed successfully."
      finishStreamingAssistant()
      updateHistoryOutcome(.completed)

    case .runCancelled:
      resetAuthorizations()
      runState = .cancelled
      currentRunRequest = nil
      isFailedRunRetryAvailable = false
      retryRequiresFreshRunID = false
      activity = "Cancelled."
      finishStreamingAssistant()
      updateHistoryOutcome(.cancelled)

    case .runFailed(let failure):
      resetAuthorizations()
      runState = .failed
      isFailedRunRetryAvailable =
        failure.isRetryable && currentRunRequest != nil
        && !currentRunMayHaveToolEffects
      retryRequiresFreshRunID = isFailedRunRetryAvailable
      activity = "Run failed."
      finishStreamingAssistant()
      updateHistoryOutcome(.failed)
      errorMessage = "Run failed (\(failure.code.rawValue)): \(failure.message)"
      if currentRunMayHaveToolEffects {
        errorMessage =
          (errorMessage ?? "Run failed.")
          + " A tool action may already have happened. Hex will not automatically start this request again; inspect the result before deciding what to do next."
      }
    }
  }

  private func retireAuthorizations(_ requestIDs: Set<AuthorizationRequestID>) {
    guard !requestIDs.isEmpty else { return }
    pendingAuthorizations.removeAll { requestIDs.contains($0.id) }
    submittedAuthorizationIDs.subtract(requestIDs)
    if let submittingID = authorizationSubmittingRequestID, requestIDs.contains(submittingID) {
      // Invalidate an in-flight submission so its late response cannot restore stale UI state.
      authorizationSubmissionID = nil
      authorizationSubmittingRequestID = nil
      isSubmittingAuthorization = false
    }
    if runState != .cancelling {
      runState = pendingAuthorizations.isEmpty ? .running : .waitingForAuthorization
    }
  }

  private func applyInferenceEvent(_ event: InferenceStreamEvent) {
    switch event {
    case .started:
      activity = "Provider connected."
    case .textDelta(let text):
      appendAssistantDelta(text)
      activity = "Streaming assistant response…"
    case .reasoningSummaryDelta:
      activity = "Reasoning…"
    case .toolCall(let call):
      activity = "Preparing \(call.name)…"
    case .usage(let usage):
      activity = "Used \(usage.outputTokens) output tokens."
    case .completed(let reason):
      activity = "Inference finished (\(stopReasonLabel(reason)))."
    }
  }

  private func shortID(for runID: AgentRunID) -> String {
    String(runID.rawValue.uuidString.prefix(8))
  }
}
