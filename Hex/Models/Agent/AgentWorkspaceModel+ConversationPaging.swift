import Foundation
import HexCore

extension AgentWorkspaceModel {
  var usesPagedConversations: Bool { conversationStore is any AgentPagedConversationStoring }

  /// Discard only projections whose exact source snapshot has a durable receipt. An event received
  /// during the save keeps its complete working data until the next checkpoint succeeds.
  func adoptSavedWorkingSet(_ archive: AgentConversationArchive) {
    guard !isPreparingAdmission else { return }
    for saved in archive.conversations where saved.history != nil {
      guard let index = conversations.firstIndex(where: { $0.id == saved.id }),
        conversations[index] == saved,
        let history = try? AgentConversationContextProjection.workingHistory(
          in: saved.resolvedHistory())
      else { continue }
      var working = saved
      working.history = history
      if let state = try? AgentSQLiteConversationStore.state(for: saved),
        let durable = try? JSONDecoder().decode(AgentConversation.self, from: state)
      {
        working.artifactSources = durable.artifactSources
        working.artifactInventory = durable.artifactInventory
      }
      if saved.id != selectedConversationID {
        working.history = nil
        working.transcript = []
        working.pendingRun = nil
        working.artifactInventory = nil
        working.artifactSources = nil
      }
      if saved.id == selectedConversationID && transcript == saved.transcript && isRunActive {
        working.transcript = Array(saved.transcript.suffix(100))
        if working.transcript.count < saved.transcript.count {
          hasEarlierTranscript = true
          olderTranscriptCursor = nil
        }
        transcript = working.transcript
      }
      conversations[index] = working
      conversationPersistenceState.persistableConversations[saved.id] = working
      savedConversationSnapshots[saved.id] = working
    }
  }

  func selectPagedConversation(_ id: UUID, repository: any AgentPagedConversationStoring) {
    guard !isRunActive, selectedConversationID != id, conversationArchiveWritesAreAllowed() else {
      return
    }
    persistConversationArchive()
    isLoadingConversation = true
    Task { [weak self] in
      guard let self else { return }
      defer { isLoadingConversation = false }
      guard await saveArchiveNow(persistenceArchive(replacing: nil)) else { return }
      do {
        let conversation = try await repository.readConversation(id)
        try await repository.saveChanges([], selected: id)
        evictConversationWorkingSets(except: id)
        if let index = conversations.firstIndex(where: { $0.id == id }) {
          conversations[index] = conversation
        } else {
          conversations.append(conversation)
        }
        selectedConversationID = id
        conversationPersistenceState.persistableConversations[id] = conversation
        savedConversationSnapshots[id] = conversation
        restoreComposerSelection(from: conversation)
        transcript = recoveredTranscript(conversation.transcript)
        olderTranscriptCursor = nil
        isViewingEarlierTranscript = false
        let page = try await repository.earlierTranscript(id, before: nil)
        olderTranscriptCursor = page.before
        hasEarlierTranscript = page.before != nil
        resetRunStateForConversationSwitch()
        errorMessage = nil
        restorePendingRun(from: conversation)
        activity = "Conversation restored."
        isLoadingConversation = false
        scheduleRestoredRunRecovery()
      } catch { conversationPersistenceDidFail() }
    }
  }

  func loadEarlierTranscript() async {
    guard !isRunActive, let id = selectedConversationID,
      let repository = conversationStore as? any AgentPagedConversationStoring
    else { return }
    isLoadingConversation = true
    defer { isLoadingConversation = false }
    do {
      if olderTranscriptCursor == nil {
        let latest = try await repository.earlierTranscript(id, before: nil)
        olderTranscriptCursor = latest.before
        if olderTranscriptCursor == nil {
          hasEarlierTranscript = false
          return
        }
      }
      var page = try await repository.earlierTranscript(id, before: olderTranscriptCursor)
      let existing = Set(transcript.map(\.id))
      while page.items.allSatisfy({ existing.contains($0.id) }), let before = page.before {
        page = try await repository.earlierTranscript(id, before: before)
      }
      transcript = Array((page.items.filter { !existing.contains($0.id) } + transcript).prefix(150))
      isViewingEarlierTranscript = true
      olderTranscriptCursor = page.before
      hasEarlierTranscript = page.before != nil
      // Older rows are a display page only, never reintroduced into inference context.
      if let index = conversations.firstIndex(where: { $0.id == id }) {
        conversations[index].transcript = transcript
      }
    } catch { errorMessage = "Earlier messages could not be loaded. Saved history is unchanged." }
  }

  func loadLatestTranscript() async {
    guard !isRunActive, let id = selectedConversationID,
      let repository = conversationStore as? any AgentPagedConversationStoring
    else { return }
    isLoadingConversation = true
    defer { isLoadingConversation = false }
    do {
      let page = try await repository.earlierTranscript(id, before: nil)
      transcript = page.items
      olderTranscriptCursor = page.before
      hasEarlierTranscript = page.before != nil
      isViewingEarlierTranscript = false
      if let index = conversations.firstIndex(where: { $0.id == id }) {
        conversations[index].transcript = transcript
      }
    } catch { errorMessage = "Latest messages could not be loaded. Your draft is unchanged." }
  }

  func queryConversationPage(_ query: ConversationStorageRequest.Query) async throws
    -> (ids: [UUID], next: ConversationStorageRequest.Cursor?)
  {
    guard let repository = conversationStore as? any AgentPagedConversationStoring else {
      return ([], nil)
    }
    let page = try await repository.listConversations(query)
    try Task.checkCancellation()
    for metadata in page.conversations {
      if let index = conversations.firstIndex(where: { $0.id == metadata.id }) {
        if conversations[index].history == nil { conversations[index] = metadata }
      } else {
        conversations.append(metadata)
      }
      if savedConversationSnapshots[metadata.id] == nil {
        savedConversationSnapshots[metadata.id] = metadata
      }
    }
    return (page.conversations.map(\.id), page.next)
  }

  func deletePagedConversation(_ id: UUID, repository: any AgentPagedConversationStoring) {
    guard !isRunActive, conversationArchiveWritesAreAllowed() else { return }
    persistConversationArchive()
    isLoadingConversation = true
    Task { [weak self] in
      guard let self else { return }
      defer { isLoadingConversation = false }
      guard await saveArchiveNow(persistenceArchive(replacing: nil)) else { return }
      do {
        try await repository.removeConversation(id)
        conversations.removeAll { $0.id == id }
        conversationPersistenceState.persistableConversations.removeValue(forKey: id)
        savedConversationSnapshots.removeValue(forKey: id)
        if selectedConversationID == id {
          selectedConversationID = nil
          transcript = []
          resetRunStateForConversationSwitch()
        }
        conversationListRevision &+= 1
        activity = "Conversation deleted."
      } catch { conversationPersistenceDidFail() }
    }
  }

  func evictConversationWorkingSets(except id: UUID) {
    for index in conversations.indices where conversations[index].id != id {
      var metadata = conversations[index]
      metadata.transcript = []
      metadata.history = nil
      metadata.pendingRun = nil
      metadata.artifactInventory = nil
      metadata.artifactSources = nil
      conversations[index] = metadata
      conversationPersistenceState.persistableConversations[metadata.id] = metadata
      savedConversationSnapshots[metadata.id] = metadata
    }
  }
}
