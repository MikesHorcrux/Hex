import CryptoKit
import Foundation
import HexCore

extension HexGatewayService {
  public func taskOperation(_ untrusted: GatewayTaskRequest, sessionID: GatewaySessionID)
    async throws -> GatewayTaskRequest.Response
  {
    let request = try codec.roundTrip(untrusted)
    try requireSession(sessionID)
    guard let taskStore, driver is any HexGatewayBoundaryStopping, historyReader != nil else {
      throw taskFailure("This gateway does not support durable task execution.")
    }
    var response = GatewayTaskRequest.Response()
    switch request {
    case .adoptLegacyConversation(let id):
      try requireAcceptingAdmissions()
      response.tasks = try await adoptLegacyConversation(id)
      wakeTaskScheduler()
    case .conversationTasks(let id, let before, let limit):
      response.tasks = try await taskStore.conversationTasks(id, before: before, limit: limit)
      response.activeTask = try await taskStore.activeConversationTask(id)
      if response.tasks.count == limit { response.next = response.tasks.last?.id }
    case .conversationHistory(let id, let before, let limit):
      let page = try await taskStore.conversationTimeline(id, before: before, limit: limit)
      response.timeline = page.entries
      response.before = page.before
    case .list(let after, let limit):
      guard (1...20).contains(limit) else { throw taskFailure("Invalid task page size.") }
      response.tasks = try await taskStore.listTasks(
        after: after, limit: limit, unfinishedOnly: false)
      if response.tasks.count == limit { response.next = response.tasks.last?.id }
    case .attempts(let id, let before, let limit):
      response.attempts = try await taskStore.taskAttempts(id, before: before, limit: limit)
    case .read(let id):
      if let record = try await taskStore.readTask(id) { response.tasks = [record.summary] }
    case .submit(let id, let title, let run),
      .submitConversation(let id, _, _, let title, let run):
      let conversationID: UUID
      let predecessorID: UUID?
      if case .submitConversation(_, let parent, let previous, _, _) = request {
        conversationID = parent
        predecessorID = previous
      } else {
        conversationID = id
        predecessorID = nil
      }
      try requireValidGatewayIdentity(conversationID, message: "Invalid conversation identity.")
      try requireAcceptingAdmissions()
      try requireValidGatewayIdentity(id, message: "Invalid task identity.")
      try requireValidGatewayIdentity(run.runID.rawValue, message: "Invalid attempt identity.")
      guard !title.isEmpty, title.utf8.count <= 1_024, !run.initialMessages.isEmpty else {
        throw taskFailure("A task needs a title and an instruction.")
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let payload = try encoder.encode(run)
      guard payload.count <= 3 * 1_024 * 1_024 else {
        throw taskFailure(
          "The task context exceeds one admission envelope. Compact it before admission.")
      }
      let hash = Data(SHA256.hash(data: payload))
      if let old = try await taskStore.readTask(id) {
        guard old.admissionHash == hash, old.title == title,
          (old.conversationID ?? old.id) == conversationID, old.predecessorID == predecessorID
        else {
          throw taskFailure("That task identity already belongs to different work.")
        }
        response.tasks = [old.summary]
      } else {
        let ownedRequest = GatewayStartRunRequest(
          runID: AgentRunID(), modelID: run.modelID,
          initialMessages: run.initialMessages, options: run.options, toolChoice: run.toolChoice,
          workingDirectory: run.workingDirectory, availableArtifacts: run.availableArtifacts,
          authorizationMode: run.authorizationMode)
        var record = AgentTaskRecord(
          id: id, title: title,
          request: try encoder.encode(ownedRequest), admissionHash: hash)
        record.conversationID = conversationID
        record.predecessorID = predecessorID
        record.userMessage = run.initialMessages.last
        guard record.userMessage?.role == .user else {
          throw taskFailure("A user message is required.")
        }
        if predecessorID != nil, run.initialMessages.count != 1 {
          throw taskFailure("Follow-up context is assembled by the resident.")
        }
        do {
          response.tasks = [try await taskStore.saveTask(record).summary]
        } catch AgentTaskStorageError.revisionConflict {
          throw GatewayFailure(
            code: .conversationChanged,
            message:
              "Another message changed this conversation. Your draft was retained; send it again with the latest context."
          )
        }
      }
      wakeTaskScheduler()
    case .control(let id, let revision, let operationID, let action):
      try requireAcceptingAdmissions()
      guard var record = try await taskStore.readTask(id) else {
        throw taskFailure("Task not found.")
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let hash = Data(SHA256.hash(data: try encoder.encode(action)))
      if record.lastControlID == operationID {
        guard record.lastControlHash == hash else {
          throw taskFailure("Conflicting control identity.")
        }
        response.tasks = [record.summary]
        break
      }
      guard record.revision == revision, !record.phase.isTerminal else {
        throw GatewayFailure(
          code: .conversationChanged,
          message:
            "The work changed before this message was applied. Your draft was retained; send it again."
        )
      }
      switch action {
      case .pause:
        record.phase = record.attemptPending ? .pausing : .paused
        record.explanation =
          record.attemptPending ? "Pausing after dispatched work is recorded" : "Paused"
      case .cancel:
        record.phase = record.attemptPending ? .cancelling : .cancelled
        record.explanation =
          record.attemptPending ? "Cancelling; waiting for dispatched work" : "Cancelled"
      case .resume:
        guard !record.attemptPending, record.phase != .blocked else {
          throw taskFailure("Wait for the current attempt, or reconcile the blocked outcome first.")
        }
        record.phase = .queued
        record.notBefore = nil
        record.retryCount = 0
        record.explanation = "Queued to continue"
      case .steer(let text):
        try validateTaskInstruction(text)
        guard record.instructions.count < 64, record.phase != .blocked else {
          throw taskFailure(
            "Reconcile the blocked task or wait for pending steering to be applied.")
        }
        record.instructions.append(.init(id: operationID, text: text))
        record.phase =
          record.phase == .paused ? .paused : (record.attemptPending ? .waiting : .queued)
        record.explanation =
          record.phase == .paused
          ? "Message saved; resume when ready"
          : (record.attemptPending
            ? "Steering saved; waiting for dispatched work" : "Steering queued")
      case .reconcile(let text):
        try validateTaskInstruction(text)
        guard record.phase == .blocked, !record.attemptPending else {
          throw taskFailure("Only a stopped, blocked task can be reconciled.")
        }
        record.reconciliation = text
        // Re-read the original attempt evidence; do not manufacture a journal receipt.
        record.attemptPending = true
        record.phase = .waiting
        record.retryCount = 0
        record.explanation = "Applying your reconciliation decision"
      }
      record.lastControlID = operationID
      record.lastControlHash = hash
      let saved: AgentTaskRecord
      do { saved = try await taskStore.saveTask(record) } catch AgentTaskStorageError
        .revisionConflict
      {
        throw GatewayFailure(
          code: .conversationChanged,
          message: "The work changed before this control was applied. Refresh and try again.")
      }
      response.tasks = [saved.summary]
      if saved.attemptPending, let runID = saved.runID,
        activeRunID == runID || taskDispatchReservation == runID,
        let boundaryDriver = driver as? any HexGatewayBoundaryStopping
      {
        await boundaryDriver.stopAtBoundary(runID)
      }
      wakeTaskScheduler()
    }
    try requireSession(sessionID)
    response.schedulerFailure = taskSchedulerFailure
    if taskSchedulerFailure != nil { wakeTaskScheduler() }
    return try codec.roundTrip(response)
  }

  func taskFailure(_ message: String) -> GatewayFailure {
    GatewayFailure(code: .taskRequestRejected, message: message)
  }

  private func validateTaskInstruction(_ text: String) throws {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf8.count <= 16_384
    else { throw taskFailure("Enter a steering instruction of at most 16 KiB.") }
  }
}
