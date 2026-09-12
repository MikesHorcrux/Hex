import Foundation
import HexCore
import HexIPC
import Observation

@MainActor
@Observable
final class AgentTaskWorkspaceModel {
  let client: any HexAgentClient
  let taskClient: any HexGatewayTaskClient
  var tasks: [AgentTaskRecord] = []
  var selectedID: UUID?
  var draft = ""
  var steering = ""
  var error: String?
  var isSubmitting = false
  var controlOperation: (taskID: UUID, revision: Int64, id: UUID, action: GatewayTaskAction)?
  var items: [ConversationItem] = []
  var approvals: [AuthorizationRequest] = []
  var nextPage: UUID?
  var attempts: [AgentTaskAttempt] = []
  var historicalRunID: AgentRunID?
  var inspectingHistory = false
  var historyPageStarts: [UInt64] = []
  var historyHasMore = false
  var observedRunID: AgentRunID?
  var sequence: UInt64 = 0
  var hasInference = false
  var observationGeneration = UUID()
  var submission: (id: UUID, title: String, request: GatewayStartRunRequest)?
  var selected: AgentTaskRecord? { tasks.first { $0.id == selectedID } }

  init(client: any HexAgentClient, taskClient: any HexGatewayTaskClient) {
    self.client = client
    self.taskClient = taskClient
  }

  func refresh(more: Bool = false) async {
    do {
      let response = try await taskClient.taskOperation(
        .list(after: more ? nextPage : nil, limit: 20))
      if more {
        tasks += response.tasks.filter { value in !tasks.contains { $0.id == value.id } }
      } else {
        for value in response.tasks { update(value) }
        if tasks.isEmpty { tasks = response.tasks }
      }
      nextPage = response.next
      error = response.schedulerFailure
      if selectedID == nil { selectedID = tasks.sorted { $0.createdAt > $1.createdAt }.first?.id }
      if let selectedID {
        let response = try await taskClient.taskOperation(.read(selectedID))
        if let value = response.tasks.first { update(value) }
      }
      if let selectedID, attempts.first?.number != selected?.attemptCount {
        let recent = try await taskClient.taskOperation(
          .attempts(selectedID, before: nil, limit: 20)
        ).attempts
        attempts = recent + attempts.filter { prior in !recent.contains { $0.id == prior.id } }
      }
      if !inspectingHistory { try await readSelectedAttempt() }
    } catch is CancellationError { return } catch {
      self.error =
        (error as? GatewayFailure)?.message
        ?? "Could not refresh saved tasks. Reconnect and refresh."
    }
  }

  func submit(_ request: GatewayStartRunRequest, title: String) async {
    guard !isSubmitting else { return }
    isSubmitting = true
    defer { isSubmitting = false }
    if submission == nil { submission = (UUID(), title, request) }
    guard let submission else { return }
    do {
      let response = try await taskClient.taskOperation(
        .submit(
          id: submission.id,
          title: submission.title, request: submission.request))
      if let value = response.tasks.first {
        update(value)
        select(value.id)
      }
      self.submission = nil
      draft = ""
      error = nil
    } catch {
      self.error =
        "Admission was not acknowledged. Retry sends the same saved task identity; it cannot create a duplicate."
    }
  }

  func control(_ action: GatewayTaskAction) async {
    guard let selected, !isSubmitting else { return }
    isSubmitting = true
    defer { isSubmitting = false }
    if controlOperation?.taskID != selected.id || controlOperation?.action != action {
      controlOperation = (selected.id, selected.revision, UUID(), action)
    }
    guard let operation = controlOperation else { return }
    do {
      let response = try await taskClient.taskOperation(
        .control(
          id: operation.taskID,
          revision: operation.revision, operationID: operation.id, action: operation.action))
      if let value = response.tasks.first { update(value) }
      steering = ""
      controlOperation = nil
      error = nil
    } catch {
      if let code = (error as? GatewayFailure)?.code,
        code == .conversationChanged || code == .taskRequestRejected
      {
        controlOperation = nil
      }
      self.error =
        (error as? GatewayFailure)?.message
        ?? "The task changed. Refresh before trying this control again."
    }
  }

  func select(_ id: UUID) {
    guard id != selectedID else { return }
    selectedID = id
    observedRunID = nil
    sequence = 0
    hasInference = false
    items = []
    approvals = []
    observationGeneration = UUID()
    attempts = []
    historicalRunID = nil
    inspectingHistory = false
    historyPageStarts = []
  }

  func update(_ record: AgentTaskRecord) {
    if let operation = controlOperation, operation.taskID == record.id,
      record.lastControlID == operation.id
    {
      controlOperation = nil
      steering = ""
    }
    if let index = tasks.firstIndex(where: { $0.id == record.id }) {
      if tasks[index].revision <= record.revision { tasks[index] = record }
    } else {
      tasks.append(record)
    }
  }

  func decide(_ request: AuthorizationRequest, choice: AuthorizationDecisionChoice) async {
    do { try await client.decideAuthorization(request, choice: choice) } catch {
      self.error = "The approval changed or the gateway disconnected. Refresh the task."
    }
  }
}
