import Foundation

extension AgentWorkspaceModel {
  func restoreConversationHistory() async {
    guard !didRestoreConversations else {
      return
    }
    didRestoreConversations = true

    guard let conversationStore else {
      return
    }

    isRestoringConversations = true
    defer {
      isRestoringConversations = false
    }

    do {
      guard let archive = try await conversationStore.load() else {
        return
      }

      conversations = archive.conversations
      let restoredID = archive.selectedConversationID ?? orderedConversations.first?.id
      guard let restoredID, let conversation = conversation(withID: restoredID) else {
        selectedConversationID = nil
        transcript = []
        return
      }
      selectedConversationID = conversation.id
      transcript = recoveredTranscript(conversation.transcript)
      activity = "Conversation history restored."
    } catch {
      conversations = []
      selectedConversationID = nil
      transcript = []
      activity = "Saved conversation history is unavailable."
      errorMessage =
        "Saved conversation history could not be restored. The saved archive was left untouched."
    }
  }

  func newConversation() {
    guard !isRunActive else {
      errorMessage = "Finish or cancel the active run before starting a new conversation."
      return
    }

    persistConversationArchive()
    let conversation = AgentConversation()
    conversations.insert(conversation, at: 0)
    selectedConversationID = conversation.id
    transcript = []
    resetRunStateForConversationSwitch()
    errorMessage = nil
    activity = "Ready for a prompt."
    persistConversationArchive()
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
    transcript = recoveredTranscript(conversation.transcript)
    resetRunStateForConversationSwitch()
    errorMessage = nil
    activity = "Ready for a prompt."
    persistConversationArchive()
  }

  func ensureCurrentConversation() -> AgentConversation {
    if let selectedConversationID, let conversation = conversation(withID: selectedConversationID) {
      return conversation
    }

    let conversation = AgentConversation()
    conversations.insert(conversation, at: 0)
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
    if let prompt {
      conversations[index].recordPrompt(prompt)
    } else {
      conversations[index].updatedAt = max(Date(), conversations[index].createdAt)
    }
  }

  func persistConversationArchive() {
    guard let conversationStore else {
      return
    }

    updateCurrentConversation()
    let archive = AgentConversationArchive(
      selectedConversationID: selectedConversationID,
      conversations: conversations
    )
    conversationPersistenceTask?.cancel()
    conversationPersistenceTask = Task { [weak self, conversationStore, archive] in
      do {
        try await conversationStore.save(archive)
      } catch is CancellationError {
        return
      } catch {
        self?.conversationPersistenceDidFail()
      }
    }
  }

  private func conversation(withID id: UUID) -> AgentConversation? {
    conversations.first(where: { $0.id == id })
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
    streamingAssistantItemID = nil
    pendingInitialMessageIDs.removeAll()
    runState = .idle
    pendingAuthorization = nil
    isSubmittingAuthorization = false
  }

  private func conversationPersistenceDidFail() {
    if errorMessage == nil {
      errorMessage = "Hex could not save conversation history. New messages remain in this session."
    }
    activity = "Conversation history could not be saved."
  }
}
