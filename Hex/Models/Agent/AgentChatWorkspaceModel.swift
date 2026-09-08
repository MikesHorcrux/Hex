import Foundation
import HexCore
import HexIPC
import Observation

/// Window-scoped projection and drafts. The resident owns conversation identity, order and execution.
@MainActor
@Observable
final class AgentChatWorkspaceModel {
  let client: any HexAgentClient
  let taskClient: any HexGatewayTaskClient
  let storage: any ConversationStorage
  let execution: AgentTaskWorkspaceModel
  var conversations: [ConversationStorageRequest.Document] = []
  var selectedID: UUID?
  var selectedDocument: ConversationStorageRequest.Document?
  var newID = UUID()
  var drafts: [UUID: String] = [:]
  var draft: String {
    get { drafts[selectedID ?? newID] ?? "" }
    set { drafts[selectedID ?? newID] = newValue }
  }
  var items: [ConversationItem] = []
  var work: [AgentTaskRecord] = []
  var activeWork: AgentTaskRecord?
  var error: String?
  var isSubmitting = false
  var isLoading = false
  var initialized = false
  var storageReady = false
  var isPreparingStorage = false
  var generation = UUID()
  var nextConversation: ConversationStorageRequest.Cursor?
  var before: Int64?
  var legacyBefore: Int64?
  var legacyExhausted = false
  var showingEarlier = false
  var search = ""
  var showsArchived = false
  var pending: (conversationID: UUID, request: GatewayTaskRequest, draft: String)?
  var selected: ConversationStorageRequest.Document? {
    selectedDocument?.id == selectedID
      ? selectedDocument : conversations.first { $0.id == selectedID }
  }
  var currentWork: AgentTaskRecord? { activeWork ?? work.first }
  var hasEarlier: Bool { before != nil || !legacyExhausted }

  init(
    client: any HexAgentClient, taskClient: any HexGatewayTaskClient,
    storage: any ConversationStorage
  ) {
    self.client = client
    self.taskClient = taskClient
    self.storage = storage
    execution = AgentTaskWorkspaceModel(client: client, taskClient: taskClient)
  }

  func refresh(more: Bool = false) async {
    guard storageReady, !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    let token = generation
    var recoveryError: String?
    do {
      let page = try await storage.conversationStorage(
        .list(
          .init(
            search: search,
            archived: showsArchived, after: more ? nextConversation : nil, limit: 30)))
      guard token == generation else { return }
      if more {
        conversations += page.documents.filter { row in !conversations.contains { $0.id == row.id }
        }
      } else {
        let existing = conversations
        conversations =
          page.documents + existing.filter { row in !page.documents.contains { $0.id == row.id } }
      }
      nextConversation = page.next
      if !initialized {
        initialized = true
        let status = try await storage.conversationStorage(.status)
        guard token == generation else { return }
        let restored = status.selected ?? conversations.first?.id
        if let restored { selectedID = restored }
      }
      if let id = selectedID {
        let document = try await storage.conversationStorage(.read(id)).documents.first
        guard token == generation, id == selectedID else { return }
        selectedDocument = document
        do { _ = try await taskClient.taskOperation(.adoptLegacyConversation(id)) } catch {
          recoveryError =
            (error as? GatewayFailure)?.message ?? "Older saved work could not be recovered."
        }
        let response = try await taskClient.taskOperation(
          .conversationTasks(id, before: nil, limit: 20))
        guard token == generation, id == selectedID else { return }
        work = response.tasks
        activeWork = response.activeTask
        recoveryError = recoveryError ?? response.schedulerFailure
        if let task = currentWork {
          execution.update(task)
          execution.select(task.id)
          if !task.phase.isTerminal {
            try await execution.readSelectedAttempt()
          } else {
            execution.approvals = []
          }
        }
        if !showingEarlier { try await loadTimeline(id, before: nil, token: token) }
      }
      if pending == nil { error = recoveryError }
    } catch is CancellationError { return } catch {
      self.error =
        (error as? GatewayFailure)?.message
        ?? "Could not refresh the conversation. Reconnect and try again."
    }
  }

  /// Admission stays disabled until the existing archive has been imported successfully.
  /// The polling owner retries after a reconnect, including a resident protocol upgrade.
  func prepareHistory(workspace: AgentWorkspaceModel) async {
    guard !storageReady, !isPreparingStorage, workspace.connectionState == .connected else {
      return
    }
    isPreparingStorage = true
    defer { isPreparingStorage = false }
    do {
      _ = try await workspace.conversationStore?.load()
      workspace.didRestoreConversations = true
      storageReady = true
      error = nil
    } catch {
      self.error = "Saved conversations could not be imported. Reconnect to retry."
    }
  }

  func select(_ id: UUID?) {
    guard !isSubmitting else { return }
    generation = UUID()
    selectedID = id
    selectedDocument = nil
    if id == nil { newID = UUID() }
    initialized = true
    items = []
    work = []
    activeWork = nil
    before = nil
    legacyBefore = nil
    legacyExhausted = false
    showingEarlier = false
    error = nil
    execution.approvals = []
    Task {
      do { _ = try await storage.conversationStorage(.select(id)) } catch {
        self.error = "The conversation selection could not be saved."
      }
      await refresh()
    }
  }

  func filterChanged() {
    generation = UUID()
    conversations = []
    nextConversation = nil
    Task { await refresh() }
  }
}
