import Foundation
import HexCore
import HexIPC

extension AgentChatWorkspaceModel {
  func send(workspace: AgentWorkspaceModel, enqueue: Bool = false) async {
    guard !isSubmitting else { return }
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard pending != nil || !text.isEmpty else { return }
    guard workspace.connectionState == .connected else {
      error = "Connect to Hex Agent before sending."
      return
    }
    await prepareHistory(workspace: workspace)
    guard storageReady else { return }
    isSubmitting = true
    defer { isSubmitting = false }
    let parent = selectedID ?? newID
    do {
      if pending == nil {
        _ = try await taskClient.taskOperation(.adoptLegacyConversation(parent))
        let response = try await taskClient.taskOperation(
          .conversationTasks(parent, before: nil, limit: 20))
        let current = response.tasks
        work = current
        activeWork = response.activeTask
        if let active = response.activeTask, !enqueue {
          let action: GatewayTaskRequest.Action =
            active.phase == .blocked ? .reconcile(text) : .steer(text)
          pending = (
            parent,
            .control(id: active.id, revision: active.revision, operationID: UUID(), action: action),
            text
          )
        } else {
          let previous = current.first?.id
          var context: [Message] = []
          var artifacts: [ArtifactReference] = []
          if previous == nil,
            let document = try await storage.conversationStorage(.read(parent)).documents.first,
            document.state != Data("{\"durableConversation\":1}".utf8)
          {
            let conversation = try JSONDecoder().decode(
              AgentConversation.self, from: document.state)
            guard !conversation.hasUnresolvedHistory, conversation.pendingRun == nil else {
              throw GatewayFailure(
                code: .recoveryUnavailable,
                message:
                  "This older conversation contains interrupted work. Its history is preserved; resolve its saved run before continuing."
              )
            }
            context = try AgentConversationContextProjection.messages(
              in: conversation.resolvedHistory())
            artifacts = try conversation.availableArtifacts()
          }
          let user = Message(role: .user, content: [.text(text)])
          let request = GatewayStartRunRequest(
            runID: AgentRunID(),
            modelID: ModelID(rawValue: workspace.resolvedComposerModelID),
            initialMessages: context + [user],
            options: InferenceOptions(
              reasoningEffort: workspace.selectedComposerEffort.inferenceValue),
            availableArtifacts: artifacts,
            authorizationMode: workspace.selectedComposerAuthorizationMode)
          pending = (
            parent,
            .submitConversation(
              id: UUID(), conversationID: parent,
              predecessorID: previous, title: AgentConversation.title(for: text),
              request: request), text
          )
        }
      }
      guard let saved = pending else { return }
      _ = try await taskClient.taskOperation(saved.request)
      if drafts[saved.conversationID]?.trimmingCharacters(in: .whitespacesAndNewlines)
        == saved.draft
      {
        drafts[saved.conversationID] = ""
      }
      selectedID = saved.conversationID
      pending = nil
      _ = try? await storage.conversationStorage(.select(saved.conversationID))
      error = nil
      await refresh()
    } catch {
      if let code = (error as? GatewayFailure)?.code,
        code == .conversationChanged || code == .taskRequestRejected
      {
        pending = nil
      }
      self.error =
        (error as? GatewayFailure)?.message
        ?? "Delivery was not confirmed. Retry sends the same saved message identity."
    }
  }

  func control(_ action: GatewayTaskRequest.Action) async {
    guard let task = activeWork, !isSubmitting, pending == nil else { return }
    execution.update(task)
    execution.select(task.id)
    await execution.control(action)
    await refresh()
    if let error = execution.error { self.error = error }
  }

  func rename(_ title: String) async {
    guard let id = selectedID, AgentConversation.isValidExplicitTitle(title) else { return }
    await updateMetadata(id) { $0.title = title }
  }

  func archive(_ id: UUID, archived: Bool) async {
    guard work.allSatisfy({ $0.phase.isTerminal }) || id != selectedID else {
      error = "Finish or cancel this conversation's work before archiving it."
      return
    }
    await updateMetadata(id) { $0.archivedAt = archived ? Date() : nil }
    conversations = []
    await refresh()
  }

  private func updateMetadata(
    _ id: UUID, mutation: (inout ConversationStorageRequest.Document) -> Void
  ) async {
    do {
      guard var document = try await storage.conversationStorage(.read(id)).documents.first else {
        return
      }
      mutation(&document)
      document.updatedAt = max(document.createdAt, Date())
      _ = try await storage.conversationStorage(.write(.init(document: document, entries: [])))
      if selectedID == id { selectedDocument = document }
      if let index = conversations.firstIndex(where: { $0.id == id }) {
        conversations[index] = document
      }
    } catch { self.error = "The conversation changed. Refresh and try the change again." }
  }
}
