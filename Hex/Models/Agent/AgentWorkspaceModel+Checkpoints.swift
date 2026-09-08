import Foundation
import HexCore

extension AgentWorkspaceModel {
  /// One writer serializes immutable archive snapshots. New snapshots may coalesce while a write
  /// is in flight; a later snapshot can never be overwritten by an older cancelled task.
  @discardableResult
  func queueArchiveWrite(_ archive: AgentConversationArchive, barrier: Bool = false) -> UInt64 {
    archiveRevision += 1
    let revision = archiveRevision
    guard let conversationStore else {
      savedArchiveRevision = revision
      return revision
    }
    if !barrier, archiveWriteQueue.last?.barrier == false {
      archiveWriteQueue.removeLast()
    }
    archiveWriteQueue.append((revision, archive, barrier))
    guard conversationPersistenceTask == nil else { return revision }
    conversationPersistenceTask = Task { [weak self, conversationStore] in
      guard let self else { return }
      while !archiveWriteQueue.isEmpty {
        let pending = archiveWriteQueue.removeFirst()
        let saved: Bool
        do {
          try await conversationStore.save(pending.archive)
          savedArchiveRevision = pending.revision
          conversationSaveError = nil
          saved = true
        } catch {
          conversationPersistenceDidFail()
          saved = false
        }
        archiveWriteWaiters.removeValue(forKey: pending.revision)?.resume(returning: saved)
      }
      conversationPersistenceTask = nil
    }
    return revision
  }

  func saveArchiveNow(_ archive: AgentConversationArchive) async -> Bool {
    guard !requiresConversationPersistence || conversationStore != nil else {
      conversationPersistenceDidFail()
      return false
    }
    do {
      try validatePersistenceArchive(archive)
    } catch {
      conversationPersistenceDidFail()
      return false
    }
    guard conversationStore != nil else { return true }
    let revision = queueArchiveWrite(archive, barrier: true)
    return await withCheckedContinuation { continuation in
      archiveWriteWaiters[revision] = continuation
    }
  }

  func saveCurrentRunCheckpoint() async -> Bool {
    checkpointTimer?.cancel()
    checkpointTimer = nil
    updateCurrentConversation()
    updatePendingRunCheckpoint()
    guard let selected = conversations.first(where: { $0.id == selectedConversationID }) else {
      return conversationStore == nil
    }
    return await saveArchiveNow(persistenceArchive(replacing: selected))
  }

  /// Projection and cursor are captured together, only after complete event reduction. Token-only
  /// events share a bounded timer; decisions, native messages and terminal outcomes flush sooner.
  func scheduleRunCheckpoint(for event: AgentEvent) {
    guard !isRecoveringRun else { return }
    switch event {
    case .inferenceEvent:
      guard checkpointTimer == nil else { return }
      checkpointTimer = Task { [weak self] in
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        guard let self else { return }
        checkpointTimer = nil
        persistConversationArchive()
      }
    default:
      checkpointTimer?.cancel()
      checkpointTimer = nil
      persistConversationArchive()
    }
  }

  func updatePendingRunCheckpoint() {
    guard let index = conversations.firstIndex(where: { $0.id == selectedConversationID }),
      let exchange = conversations[index].history?.exchanges.last,
      exchange.runID == currentRunID
    else { return }
    guard let request = currentRunRequest,
      exchange.outcome == .inProgress || exchange.outcome == .interrupted
    else {
      conversations[index].pendingRun = nil
      return
    }
    conversations[index].pendingRun = AgentConversationRunCheckpoint(
      request: request,
      gatewayInstanceID: currentRunGatewayInstanceID,
      invocationID: currentInvocationID,
      appliedSequence: currentAppliedSequence,
      firstEventID: currentFirstEventID,
      streamingAssistantItemID: streamingAssistantItemID,
      pendingAuthorizations: pendingAuthorizations,
      hasToolEvidence: currentRunHasToolEvidence,
      cancellationRequested: cancellationRequested)
  }
}
