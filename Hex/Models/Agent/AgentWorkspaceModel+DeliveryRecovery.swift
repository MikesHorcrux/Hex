import Foundation
import HexCore
import HexIPC

extension AgentWorkspaceModel {
  var canDisconnect: Bool {
    !isRunActive || canStopAutomaticDeliveryObservation
  }

  /// A terminal receipt can still own a draining observer, but no longer represents cancellable
  /// resident work. Recovery must verify the original invocation before offering cancellation.
  var canCancelRun: Bool {
    if isPreparingAdmission { return true }
    guard !isRecoveringRun, currentRunID != nil, currentInvocationID != nil else { return false }
    switch runState {
    case .starting, .running, .waitingForAuthorization: return true
    case .idle, .cancelling, .completed, .cancelled, .failed: return false
    }
  }

  private var canStopAutomaticDeliveryObservation: Bool {
    guard let currentRunID else { return false }
    return automaticDeliveryRecoveryRunID == currentRunID && runTask != nil
  }

  /// A delivery failure gets one read-only recovery opportunity after its old stream unwinds.
  /// This never calls startRun, and the attempted-run marker survives another attachment failure.
  func scheduleAutomaticDeliveryRecovery(
    _ request: GatewayStartRunRequest, conversationID: UUID
  ) {
    guard runTask == nil, automaticDeliveryRecoveryRunID != request.runID,
      canContinueAutomaticDeliveryRecovery(request, conversationID: conversationID),
      !conversationPersistenceState.restoreFailed, conversationSaveError == nil
    else { return }
    automaticDeliveryRecoveryRunID = request.runID
    needsRunRecovery = false
    runState = .starting
    isRecoveringRun = true
    activity = "Restoring delivery from the original task…"
    runTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if currentRunID == request.runID, selectedConversationID == conversationID {
          isRecoveringRun = false
          runTask = nil
        }
      }
      // Save the exact applied prefix before reconnecting or attaching. A disk failure must not
      // be disguised as a network problem or trigger another provider request.
      guard await saveCurrentRunCheckpoint() else {
        pauseAutomaticDeliveryRecovery(
          request, conversationID: conversationID,
          message:
            "Automatic recovery paused because the task checkpoint could not be saved. Restore saving, then retry recovery; the task was not sent again."
        )
        return
      }
      guard canContinueAutomaticDeliveryRecovery(request, conversationID: conversationID) else {
        pauseAutomaticDeliveryRecovery(request, conversationID: conversationID)
        return
      }
      if connectionState == .disconnected {
        await connect()
      }
      guard canContinueAutomaticDeliveryRecovery(request, conversationID: conversationID),
        connectionState == .connected
      else {
        pauseAutomaticDeliveryRecovery(request, conversationID: conversationID)
        return
      }
      isRecoveringRun = false
      await recoverCurrentRun()
    }
  }

  /// Disconnect stops only this observer. The resident's execution is neither cancelled nor
  /// repeated, and its original checkpoint remains available for a later explicit recovery.
  func cancelAutomaticDeliveryRecoveryForDisconnect() -> Bool {
    guard canStopAutomaticDeliveryObservation else { return false }
    automaticConnectionSuppressedByUser = true
    runTask?.cancel()
    return true
  }

  func isAutomaticallyRecoverableDeliveryFailure(_ error: any Error) -> Bool {
    guard let failure = error as? GatewayFailure, failure.isRetryable else { return false }
    switch failure.code {
    case .consumerTooSlow, .notConnected, .staleSession, .transportUnavailable, .disconnected,
      .producerEndedWithoutTerminalEvent, .replayUnavailable:
      return true
    default:
      return false
    }
  }

  private func canContinueAutomaticDeliveryRecovery(
    _ request: GatewayStartRunRequest, conversationID: UUID
  ) -> Bool {
    // Cancelling resident work is not cancelling this read-only observer. Its terminal receipt
    // can still be missing after a dropped stream; recover it without starting or cancelling again.
    !Task.isCancelled && !automaticConnectionSuppressedByUser
      && currentRunID == request.runID && currentRunRequest == request
      && selectedConversationID == conversationID
  }

  private func pauseAutomaticDeliveryRecovery(
    _ request: GatewayStartRunRequest, conversationID: UUID, message: String? = nil
  ) {
    guard currentRunID == request.runID, currentRunRequest == request,
      selectedConversationID == conversationID
    else { return }
    runState = .failed
    isFailedRunRetryAvailable = true
    retryRequiresFreshRunID = false
    needsRunRecovery = true
    activity = "Recovery paused. The original task has not been sent again."
    pauseStreamingAssistant()
    updateHistoryOutcome(.interrupted)
    if let message { errorMessage = message }
  }
}
