import Foundation
import HexCore
import HexIPC

extension AgentWorkspaceModel {
  func restorePendingRun(from conversation: AgentConversation) {
    guard let checkpoint = conversation.pendingRun else { return }
    currentRunID = checkpoint.request.runID
    currentRunRequest = checkpoint.request
    currentInvocationID = checkpoint.invocationID
    currentRunGatewayInstanceID = checkpoint.gatewayInstanceID
    currentAppliedSequence = checkpoint.appliedSequence
    currentFirstEventID = checkpoint.firstEventID
    streamingAssistantItemID = checkpoint.streamingAssistantItemID
    pendingAuthorizations = checkpoint.pendingAuthorizations
    submittedAuthorizationIDs.removeAll()
    currentRunHasToolEvidence = checkpoint.hasToolEvidence
    cancellationRequested = checkpoint.cancellationRequested
    pendingInitialMessageIDs = Set(checkpoint.request.initialMessages.map(\.id))
    needsRunRecovery = true
    isFailedRunRetryAvailable = true
    retryRequiresFreshRunID = false
    runState = .failed
    activity = "Saved task found. Connect to recover its original progress."
  }

  func scheduleRestoredRunRecovery() {
    guard !isPreparingAdmission, needsRunRecovery, connectionState == .connected, runTask == nil
    else {
      return
    }
    needsRunRecovery = false
    runState = .starting
    runTask = Task { [weak self] in await self?.recoverCurrentRun() }
  }

  /// A read-only status/history query is the recovery entry point. Unknown evidence is never an
  /// admission retry. In particular, no invocation is fabricated for journal-only recovery.
  func recoverCurrentRun() async {
    guard let request = currentRunRequest, !isRecoveringRun else { return }
    let runID = request.runID
    let conversationID = selectedConversationID
    isRecoveringRun = true
    runState = .starting
    activity = "Recovering the original task…"
    errorMessage = nil
    defer {
      if currentRunID == runID, selectedConversationID == conversationID {
        isRecoveringRun = false
        runTask = nil
      }
    }
    do {
      // Journal replay and attachment are not atomic. A producer can advance or finish while
      // pages are being saved. Refresh a raced live cursor within this one read-only recovery.
      for attachmentAttempt in 0..<3 {
        let response = try await client.recoverRun(GatewayRunRecoveryRequest(runID: runID))
        try requireCurrentRecovery(runID: runID, gatewayInstanceID: response.gatewayInstanceID)
        guard response.runID == runID else { throw invalidRecovery() }
        switch response.disposition {
        case .unknown:
          throw GatewayFailure(
            code: .runNotFound,
            message:
              "No recoverable record of this task was found. Its outcome is unknown; Hex has not sent it again."
          )
        case .journaled(let journal):
          guard journal.terminalRecord != nil else { throw invalidRecovery() }
          try await recoverHistory(
            journal, through: journal.latestSequence,
            gatewayInstanceID: response.gatewayInstanceID, runID: runID)
          guard currentRunRequest == nil || isTerminalHistory(runID: runID) else {
            throw invalidRecovery()
          }
        case .resident(let snapshot, let minimumReplaySequence, let journal):
          guard snapshot.runID == runID, snapshot.latestSequence >= currentAppliedSequence else {
            throw invalidRecovery()
          }
          if let priorInvocation = currentInvocationID {
            guard priorInvocation == snapshot.invocationID,
              currentRunGatewayInstanceID == response.gatewayInstanceID
            else {
              throw GatewayFailure(
                code: .staleSession,
                message:
                  "The saved task belongs to a different resident invocation. No action was repeated."
              )
            }
          }
          currentInvocationID = snapshot.invocationID
          currentRunGatewayInstanceID = response.gatewayInstanceID
          updateHistoryOutcome(.inProgress)
          if let journal {
            // A commit can precede publication by one event. Stay at the resident's published prefix
            // before attaching; its later stream delivers the committed-but-unpublished suffix.
            try await recoverHistory(
              journal, through: min(journal.latestSequence, snapshot.latestSequence),
              gatewayInstanceID: response.gatewayInstanceID, runID: runID)
          }
          if isTerminalHistory(runID: runID) { return }
          guard currentAppliedSequence >= minimumReplaySequence else {
            throw GatewayFailure(
              code: .invalidEventSequence,
              message:
                "The resident no longer retains the missing events and durable history is unavailable."
            )
          }
          guard await saveCurrentRunCheckpoint() else { throw checkpointSaveFailure() }
          try requireCurrentRecovery(runID: runID, gatewayInstanceID: response.gatewayInstanceID)
          let stream: AsyncThrowingStream<GatewayEventEnvelope, any Error>
          do {
            stream = try await client.eventRecords(
              for: runID, invocationID: snapshot.invocationID, afterSequence: currentAppliedSequence
            )
          } catch let failure as GatewayFailure
            where journal != nil && attachmentAttempt < 2
            && [.invalidCursor, .replayUnavailable, .staleRunInvocation].contains(failure.code)
          {
            // Keep the applied checkpoint and identity. The next query must prove the remaining
            // history; malformed evidence and ordinary stream failures still stop immediately.
            continue
          }
          isRecoveringRun = false
          runState =
            cancellationRequested
            ? .cancelling : (pendingAuthorizations.isEmpty ? .running : .waitingForAuthorization)
          activity =
            cancellationRequested
            ? "Waiting for the original task's cancellation result…"
            : "Reconnected to the original task."
          var terminal = false
          for try await envelope in stream {
            guard currentRunID == runID else { throw CancellationError() }
            guard try await client.shouldApply(envelope) else { continue }
            try reduceRunRecord(envelope.record)
            terminal = isTerminalRunEvent(envelope.record.event)
            try await client.acknowledge(envelope)
          }
          guard terminal else {
            throw GatewayFailure(
              code: .producerEndedWithoutTerminalEvent,
              message: "The recovered stream ended before its outcome was known.", isRetryable: true
            )
          }
        }
        return
      }
    } catch {
      guard currentRunID == runID, !isTerminalHistory(runID: runID) else { return }
      if let failure = error as? GatewayFailure {
        switch failure.code {
        case .notConnected, .staleSession, .transportUnavailable, .disconnected,
          .producerEndedWithoutTerminalEvent:
          markGatewayDisconnected()
        default: break
        }
      }
      runState = .failed
      isFailedRunRetryAvailable = true
      retryRequiresFreshRunID = false
      needsRunRecovery = true
      activity = "Recovery paused. The original task has not been sent again."
      pauseStreamingAssistant()
      updateHistoryOutcome(.interrupted)
      errorMessage = actionableMessage(for: error, context: "Could not recover the original task")
    }
  }

  private func recoverHistory(
    _ journal: GatewayJournalRunSnapshot, through: UInt64,
    gatewayInstanceID: GatewayInstanceID, runID: AgentRunID
  ) async throws {
    guard journal.runID == runID, through >= currentAppliedSequence else { throw invalidRecovery() }
    if let anchor = currentFirstEventID, anchor != journal.firstEventID { throw invalidRecovery() }
    while currentAppliedSequence < through {
      let page = try await client.readRunHistory(
        GatewayRunHistoryRequest(
          runID: runID, firstEventID: journal.firstEventID, afterSequence: currentAppliedSequence,
          throughSequence: through, limit: 32))
      try requireCurrentRecovery(runID: runID, gatewayInstanceID: page.gatewayInstanceID)
      guard page.gatewayInstanceID == gatewayInstanceID, page.runID == runID,
        page.firstEventID == journal.firstEventID, page.afterSequence == currentAppliedSequence,
        page.throughSequence == through, !page.records.isEmpty, page.records.count <= 32
      else { throw invalidRecovery() }
      for record in page.records {
        guard record.sequence <= through else { throw invalidRecovery() }
        if record.sequence == 1, record.id != journal.firstEventID { throw invalidRecovery() }
        try reduceRunRecord(record)
      }
      guard (page.nextAfterSequence == nil) == (currentAppliedSequence == through),
        page.nextAfterSequence == nil || page.nextAfterSequence == currentAppliedSequence
      else { throw invalidRecovery() }
      guard await saveCurrentRunCheckpoint() else { throw checkpointSaveFailure() }
    }
  }

  private func requireCurrentRecovery(runID: AgentRunID, gatewayInstanceID: GatewayInstanceID)
    throws
  {
    try Task.checkCancellation()
    guard currentRunID == runID, connectedGatewayInstanceID == gatewayInstanceID else {
      throw GatewayFailure(
        code: .staleSession, message: "The recovery session changed. Reconnect and retry.")
    }
  }

  private func isTerminalHistory(runID: AgentRunID) -> Bool {
    guard
      let exchange = conversations.first(where: { $0.id == selectedConversationID })?
        .history?.exchanges.last, exchange.runID == runID
    else { return false }
    return [.completed, .failed, .cancelled].contains(exchange.outcome)
  }

  private func invalidRecovery() -> GatewayFailure {
    GatewayFailure(
      code: .malformedPayload,
      message:
        "Recovered task history does not match the saved request, identity or event sequence.")
  }

  private func checkpointSaveFailure() -> GatewayFailure {
    GatewayFailure(
      code: .transportUnavailable,
      message: "The recovered checkpoint could not be saved. Restore saving before continuing.")
  }
}
