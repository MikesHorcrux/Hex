import Foundation
import HexCore

extension AgentWorkspaceModel {
  func restoreConversationHistory() async {
    guard !didRestoreConversations, !isRestoringConversations else {
      return
    }

    guard let conversationStore else {
      didRestoreConversations = true
      return
    }

    isRestoringConversations = true
    defer {
      isRestoringConversations = false
    }

    do {
      let loadedArchive = try await conversationStore.load()
      didRestoreConversations = true
      guard let archive = loadedArchive else {
        return
      }

      conversations = archive.conversations.map { conversation in
        var recovered = conversation
        // Materialize legacy provenance before the display clears its streaming marker. An old
        // partial draft must not become committed inference history after a selection or save.
        recovered.history = conversation.resolvedHistory()
        if var history = recovered.history {
          for index in history.exchanges.indices
          where history.exchanges[index].outcome == .inProgress {
            history.exchanges[index].outcome = .interrupted
          }
          recovered.history = history
        }
        return recovered
      }
      conversationPersistenceState.persistableConversations = Dictionary(
        uniqueKeysWithValues: archive.conversations.map { ($0.id, $0) })
      let restoredID = archive.selectedConversationID ?? orderedConversations.first?.id
      guard let restoredID, let conversation = conversation(withID: restoredID) else {
        selectedConversationID = nil
        transcript = []
        return
      }
      selectedConversationID = conversation.id
      restoreComposerSelection(from: conversation)
      transcript = recoveredTranscript(conversation.transcript)
      activity = "Conversation history restored."
      restorePendingRun(from: conversation)
      scheduleRestoredRunRecovery()
    } catch is CancellationError {
      activity = "Conversation history loading was interrupted. Reopen the window to retry."
    } catch {
      didRestoreConversations = true
      conversationPersistenceState.restoreFailed = true
      conversations = []
      selectedConversationID = nil
      transcript = []
      activity = "Saved conversation history is unavailable."
      errorMessage =
        "Saved history could not be restored. Saving and new messages are paused to protect the original archive. Repair or move the archive, then restart Hex."
    }
  }

  func newConversation() {
    guard !isRunActive else {
      errorMessage = "Finish or cancel the active run before starting a new conversation."
      return
    }

    guard conversationArchiveWritesAreAllowed() else { return }
    updateCurrentConversation()
    persistConversationArchive()
    let conversation = AgentConversation(composerSelection: defaultComposerSelection())
    guard validateConversationAdmission(conversation) else { return }
    conversations.insert(conversation, at: 0)
    conversationPersistenceState.persistableConversations[conversation.id] = conversation
    selectedConversationID = conversation.id
    restoreComposerSelection(from: conversation)
    transcript = []
    resetRunStateForConversationSwitch()
    errorMessage = nil
    activity = "Ready for a prompt."
    restorePendingRun(from: conversation)
    persistConversationArchive()
    scheduleRestoredRunRecovery()
  }

  func selectConversation(_ id: UUID) {
    guard !isRunActive else {
      errorMessage = "Finish or cancel the active run before switching conversations."
      return
    }
    guard let conversation = conversation(withID: id) else {
      return
    }
    guard selectedConversationID != id else {
      return
    }

    persistConversationArchive()
    selectedConversationID = id
    restoreComposerSelection(from: conversation)
    transcript = recoveredTranscript(conversation.transcript)
    resetRunStateForConversationSwitch()
    errorMessage = nil
    activity = "Ready for a prompt."
    restorePendingRun(from: conversation)
    persistConversationArchive()
    scheduleRestoredRunRecovery()
  }

  func deleteConversation(_ id: UUID) {
    guard !isRunActive else {
      errorMessage = "Finish or cancel the active run before deleting a conversation."
      return
    }
    guard conversationArchiveWritesAreAllowed(), conversation(withID: id) != nil else { return }
    updateCurrentConversation()
    conversations.removeAll { $0.id == id }
    conversationPersistenceState.persistableConversations.removeValue(forKey: id)
    conversationPersistenceState.unsavedReasons.removeValue(forKey: id)
    if selectedConversationID == id {
      selectedConversationID = orderedConversations.first?.id
      if let selectedConversationID, let selected = conversation(withID: selectedConversationID) {
        transcript = recoveredTranscript(selected.transcript)
        restoreComposerSelection(from: selected)
      } else {
        transcript = []
        rememberedComposerAuthorizationMode = nil
      }
      resetRunStateForConversationSwitch()
      if let selectedConversationID, let selected = conversation(withID: selectedConversationID) {
        restorePendingRun(from: selected)
      }
    }
    errorMessage = nil
    activity = "Conversation deleted."
    persistConversationArchive()
    scheduleRestoredRunRecovery()
  }

  func canPersistPrompt(_ prompt: String, userMessage: Message, runID: AgentRunID) -> Bool {
    guard conversationArchiveWritesAreAllowed() else { return false }
    guard !conversations.contains(where: { $0.id == selectedConversationID && $0.isArchived })
    else {
      errorMessage =
        "Unarchive this conversation before sending another message. Your draft is unchanged."
      return false
    }
    var candidate =
      selectedConversationID.flatMap { conversation(withID: $0) }
      ?? AgentConversation(composerSelection: currentComposerSelection)
    candidate.transcript = transcript
    var history = candidate.resolvedHistory()
    history.exchanges.append(AgentConversationExchange(runID: runID, messages: [userMessage]))
    candidate.history = history
    candidate.transcript.append(ConversationItem(role: .user, text: prompt))
    candidate.composerSelection = currentComposerSelection
    candidate.recordPrompt(prompt)
    return validateConversationAdmission(candidate)
  }

  func ensureCurrentConversation() -> AgentConversation {
    if let selectedConversationID, let conversation = conversation(withID: selectedConversationID) {
      return conversation
    }

    let conversation = AgentConversation(composerSelection: currentComposerSelection)
    conversations.insert(conversation, at: 0)
    conversationPersistenceState.persistableConversations[conversation.id] = conversation
    selectedConversationID = conversation.id
    transcript = []
    return conversation
  }

  func updateCurrentConversation(withPrompt prompt: String? = nil) {
    guard
      let selectedConversationID,
      let index = conversations.firstIndex(where: { $0.id == selectedConversationID })
    else {
      return
    }

    conversations[index].transcript = transcript
    conversations[index].composerSelection = currentComposerSelection
    if let prompt {
      conversations[index].recordPrompt(prompt)
    } else {
      conversations[index].updatedAt = max(Date(), conversations[index].createdAt)
    }
  }

  func persistConversationArchive() {
    guard !isReducingRunEvent, !isPreparingAdmission else { return }
    updateCurrentConversation()
    updatePendingRunCheckpoint()
    guard conversationArchiveWritesAreAllowed() else { return }
    let currentConversation = selectedConversationID.flatMap { conversation(withID: $0) }
    var archive = persistenceArchive(replacing: currentConversation)
    do {
      try validatePersistenceArchive(archive)
      if let currentConversation {
        conversationPersistenceState.persistableConversations[currentConversation.id] =
          currentConversation
        conversationPersistenceState.unsavedReasons.removeValue(forKey: currentConversation.id)
      }
    } catch {
      if let currentConversation {
        conversationPersistenceState.unsavedReasons[currentConversation.id] =
          error.localizedDescription
      }
      showUnsavedConversationNotice()
      // Keep the complete output in memory, but still persist changes to other conversations
      // (including deletion) using the last persistable version of this conversation.
      archive = persistenceArchive(replacing: nil)
      do {
        try validatePersistenceArchive(archive)
      } catch {
        return
      }
    }
    showUnsavedConversationNotice()
    _ = queueArchiveWrite(archive)
  }

  func conversationArchiveWritesAreAllowed() -> Bool {
    if requiresConversationPersistence && conversationStore == nil {
      conversationSaveError =
        "Saved conversation storage is unavailable. Hex will not start unsaved work."
      errorMessage = conversationSaveError
      return false
    }
    if conversationPersistenceState.restoreFailed {
      errorMessage =
        "Saved history could not be restored. Saving and new messages are paused to protect the original archive. Repair or move the archive, then restart Hex."
      return false
    }
    if conversationStore != nil && (!didRestoreConversations || isRestoringConversations) {
      errorMessage = "Wait for saved conversation history to finish loading before making changes."
      return false
    }
    return true
  }

  func validateConversationAdmission(_ conversation: AgentConversation) -> Bool {
    do {
      try validatePersistenceArchive(persistenceArchive(replacing: conversation))
      return true
    } catch {
      errorMessage =
        "This change cannot fit in saved history. Your draft and existing history are unchanged. Start a new conversation for a full transcript, or delete an old conversation to free storage. \(error.localizedDescription)"
      return false
    }
  }

  func persistenceArchive(replacing replacement: AgentConversation?)
    -> AgentConversationArchive
  {
    var projected = conversations.map { conversation in
      if conversation.id == replacement?.id, let replacement { return replacement }
      return conversationPersistenceState.persistableConversations[conversation.id] ?? conversation
    }
    if let replacement, !projected.contains(where: { $0.id == replacement.id }) {
      projected.insert(replacement, at: 0)
    }
    return AgentConversationArchive(
      selectedConversationID: replacement?.id ?? selectedConversationID,
      conversations: projected)
  }

  func validatePersistenceArchive(_ archive: AgentConversationArchive) throws {
    if let conversationStore {
      try conversationStore.validateForPersistence(archive)
    } else {
      try AgentConversationStore.validateForPersistence(archive)
    }
  }

  private func showUnsavedConversationNotice() {
    guard !conversationPersistenceState.unsavedReasons.isEmpty else { return }
    let currentReason = selectedConversationID.flatMap {
      conversationPersistenceState.unsavedReasons[$0]
    }
    errorMessage =
      "Some conversation output is only in memory because it exceeds saved-history limits. The full output is still available in this session; keep Hex open and copy it before quitting. Other conversations can still save."
      + (currentReason.map { " \($0)" } ?? "")
    activity = "Some conversation output has not been saved."
  }

  private func conversation(withID id: UUID) -> AgentConversation? {
    conversations.first(where: { $0.id == id })
  }

  private func defaultComposerSelection() -> AgentComposerSelection {
    AgentComposerSelection(
      modelID: composerPreferenceStore?.selectedModelID(),
      effort: composerPreferenceStore?.selectedEffort() ?? .automatic
    )
  }

  private func restoreComposerSelection(from conversation: AgentConversation) {
    let selection = conversation.composerSelection ?? defaultComposerSelection()
    rememberedComposerModelID = selection.modelID
    composerEffort = selection.effort
    rememberedComposerAuthorizationMode = selection.authorizationMode
  }

  private func recoveredTranscript(_ items: [ConversationItem]) -> [ConversationItem] {
    items.map { item in
      var recovered = item
      recovered.isStreaming = false
      return recovered
    }
  }

  private func resetRunStateForConversationSwitch() {
    currentRunID = nil
    currentInvocationID = nil
    currentRunRequest = nil
    currentRunGatewayInstanceID = nil
    currentAppliedSequence = 0
    currentFirstEventID = nil
    cancellationRequested = false
    needsRunRecovery = false
    isFailedRunRetryAvailable = false
    retryRequiresFreshRunID = false
    currentRunHasToolEvidence = false
    streamingAssistantItemID = nil
    pendingInitialMessageIDs.removeAll()
    runState = .idle
    resetAuthorizations()
  }

  func conversationPersistenceDidFail() {
    conversationSaveError =
      "Hex could not save conversation history. Keep Hex open until saving succeeds."
    if errorMessage == nil {
      errorMessage = "Hex could not save conversation history. New messages remain in this session."
    }
    activity = "Conversation history could not be saved."
  }
}
