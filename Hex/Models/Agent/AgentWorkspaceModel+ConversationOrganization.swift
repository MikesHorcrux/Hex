import Foundation
import HexCore

extension AgentWorkspaceModel {
  /// Organization never switches the selected conversation. Archived conversations remain readable.
  func canOrganizeConversation(_ id: UUID) -> Bool {
    !isRunActive && !isReducingRunEvent
      && !conversationPersistenceState.restoreFailed
      && (!requiresConversationPersistence || conversationStore != nil)
      && (conversationStore == nil || (didRestoreConversations && !isRestoringConversations))
      && conversations.contains(where: { $0.id == id })
  }

  /// Returns true only after the metadata's exact archive snapshot has a successful save receipt.
  func renameConversation(_ id: UUID, to proposedTitle: String) async -> Bool {
    // Validate before trimming: control characters are not silently stripped from a requested name.
    guard AgentConversation.isValidExplicitTitle(proposedTitle) else {
      errorMessage =
        "Choose a nonblank conversation name under \(AgentConversation.maximumTitleBytes + 1) UTF-8 bytes, without line breaks or control characters."
      return false
    }
    let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    return await saveConversationOrganization(
      id, allowsSavedOutputFallback: true, saving: "Saving conversation name…",
      saved: "Conversation renamed."
    ) { conversation in
      conversation.title = title
      conversation.isTitleExplicit = true
    }
  }

  func setConversationArchived(_ id: UUID, archived: Bool) async -> Bool {
    if let repository = conversationStore as? any AgentPagedConversationStoring,
      let index = conversations.firstIndex(where: { $0.id == id }),
      conversations[index].history == nil
    {
      do { conversations[index] = try await repository.readConversation(id) } catch {
        conversationPersistenceDidFail()
        return false
      }
    }
    guard let conversation = conversations.first(where: { $0.id == id }) else {
      errorMessage = "That conversation is no longer available."
      return false
    }
    if archived {
      guard !hasUnresolvedOrganizationWork(conversation) else {
        errorMessage =
          "This conversation still has unresolved work. Recover its pending run or inspect the unknown action before archiving it. Its history remains visible."
        return false
      }
      guard conversationPersistenceState.unsavedReasons[id] == nil else {
        errorMessage =
          "Some output in this conversation is only in memory. Keep it visible and copy that output before archiving."
        return false
      }
    }
    return await saveConversationOrganization(
      id, allowsSavedOutputFallback: !archived,
      saving: archived ? "Archiving conversation…" : "Restoring conversation…",
      saved: archived
        ? "Conversation archived. Its history is preserved." : "Conversation unarchived."
    ) { conversation in
      conversation.archivedAt = archived ? max(Date(), conversation.createdAt) : nil
    }
  }

  private func saveConversationOrganization(
    _ id: UUID, allowsSavedOutputFallback: Bool, saving: String, saved: String,
    update: (inout AgentConversation) -> Void
  ) async -> Bool {
    guard conversationArchiveWritesAreAllowed() else { return false }
    guard canOrganizeConversation(id),
      let index = conversations.firstIndex(where: { $0.id == id })
    else {
      errorMessage = "Wait for active work or recovery to finish before organizing conversations."
      return false
    }
    var full = conversations[index]
    if selectedConversationID == id {
      full.transcript = transcript
      full.composerSelection = currentComposerSelection
    }
    update(&full)
    full.updatedAt = max(Date(), full.createdAt, full.updatedAt, full.archivedAt ?? full.createdAt)
    var durable = full
    var archive = organizationArchive(replacing: durable)
    var fallbackReason: String?
    do {
      try validatePersistenceArchive(archive)
    } catch {
      guard allowsSavedOutputFallback,
        var lastPersistable = conversationPersistenceState.persistableConversations[id]
      else {
        errorMessage =
          "This change could not be saved without losing conversation output. Nothing was changed. \(error.localizedDescription)"
        return false
      }
      fallbackReason = error.localizedDescription
      // A rename must also update the off-selection fallback used by every later checkpoint save.
      // Never replace the full in-memory conversation with this smaller durable snapshot.
      lastPersistable.title = full.title
      lastPersistable.isTitleExplicit = full.isTitleExplicit
      lastPersistable.archivedAt = full.archivedAt
      lastPersistable.updatedAt = full.updatedAt
      durable = lastPersistable
      archive = organizationArchive(replacing: durable)
      do { try validatePersistenceArchive(archive) } catch {
        errorMessage =
          "The conversation change could not fit in saved history. Nothing was changed."
        return false
      }
    }

    // Use the existing admission barrier to block sends, selection changes, option changes and
    // recovery scheduling until the immutable metadata save returns. No run is created or resent.
    isPreparingAdmission = true
    defer {
      isPreparingAdmission = false
      scheduleRestoredRunRecovery()
    }
    activity = saving
    errorMessage = nil
    guard await saveArchiveNow(archive) else {
      activity = "Conversation unchanged."
      errorMessage =
        "The conversation change could not be saved. Its name, archive state, and history are unchanged."
      return false
    }
    conversations[index] = full
    conversationPersistenceState.persistableConversations[id] = durable
    if let fallbackReason {
      conversationPersistenceState.unsavedReasons[id] = fallbackReason
      errorMessage =
        "The conversation change was saved, but some output is still only in memory. Keep Hex open and copy that output before quitting."
    } else {
      conversationPersistenceState.unsavedReasons.removeValue(forKey: id)
      errorMessage =
        conversationPersistenceState.unsavedReasons.isEmpty
        ? nil
        : "Some conversation output is still only in memory. Keep Hex open and copy that output before quitting."
    }
    activity = saved
    conversationListRevision &+= 1
    return true
  }

  private func organizationArchive(replacing replacement: AgentConversation)
    -> AgentConversationArchive
  {
    let existing = persistenceArchive(replacing: nil)
    return AgentConversationArchive(
      selectedConversationID: existing.selectedConversationID,
      conversations: existing.conversations.map { $0.id == replacement.id ? replacement : $0 })
  }

  private func hasUnresolvedOrganizationWork(_ conversation: AgentConversation) -> Bool {
    if conversation.pendingRun != nil || conversation.transcript.contains(where: \.isStreaming) {
      return true
    }
    if selectedConversationID == conversation.id,
      needsRunRecovery || !pendingAuthorizations.isEmpty
        || transcript.contains(where: \.isStreaming)
    {
      return true
    }
    for exchange in conversation.history?.exchanges ?? [] {
      if exchange.outcome == .inProgress { return true }
      var calls: Set<ToolCallID> = []
      for content in exchange.messages.flatMap(\.content) {
        switch content {
        case .toolCall(let call): calls.insert(call.id)
        case .toolResult(let result): calls.remove(result.toolCallID)
        default: break
        }
      }
      if !calls.isEmpty { return true }
    }
    return false
  }
}
