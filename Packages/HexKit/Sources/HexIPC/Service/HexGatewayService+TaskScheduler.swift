import Foundation
import HexCore

extension HexGatewayService {
  /// The resident owns this worker. UI disconnects never cancel admitted tasks.
  public func wakeTaskScheduler() {
    guard !admissionsClosed, taskStore != nil, historyReader != nil,
      driver is any HexGatewayBoundaryStopping
    else { return }
    taskPumpRequested = true
    guard taskPump == nil else { return }
    taskWake?.cancel()
    taskWake = nil
    taskPump = Task {
      defer {
        taskPump = nil
        resumeDrainWaitersIfIdle()
        if taskPumpRequested, !admissionsClosed { wakeTaskScheduler() }
      }
      do {
        repeat {
          taskPumpRequested = false
          try Task.checkCancellation()
          try await pumpDurableTasks()
        } while taskPumpRequested && !admissionsClosed
        taskSchedulerFailure = nil
      } catch is CancellationError {
        taskPumpRequested = false
      } catch AgentTaskStorageError.revisionConflict {
        // A newer user control won the storage transaction. Re-read instead of overwriting it.
        taskPumpRequested = true
      } catch {
        taskPumpRequested = false
        taskSchedulerFailure =
          "Task scheduling stopped because saved state could not be verified. Tasks were retained. Refresh to retry."
      }
    }
  }

  private func pumpDurableTasks() async throws {
    guard let taskStore, liveDriverTasks.isEmpty, activeRunID == nil, toolMaintenance == nil else {
      return
    }
    var cursor: UUID?
    var candidate: AgentTaskRecord?
    var wakeDate: Date?
    repeat {
      let page = try await taskStore.listTasks(after: cursor, limit: 20, unfinishedOnly: true)
      for summary in page {
        try Task.checkCancellation()
        if summary.attemptPending {
          guard let record = try await taskStore.readTask(summary.id) else { continue }
          try await reconcileTaskAttempt(record)
          taskPumpRequested = true
          continue
        }
        guard summary.phase == .queued || summary.phase == .waiting else { continue }
        if let date = summary.notBefore, date > Date() {
          wakeDate = min(wakeDate ?? date, date)
        } else if candidate == nil || summary.createdAt < (candidate?.createdAt ?? .distantFuture) {
          candidate = summary
        }
      }
      cursor = page.count == 20 ? page.last?.id : nil
    } while cursor != nil
    try Task.checkCancellation()
    guard !admissionsClosed, liveDriverTasks.isEmpty, activeRunID == nil, toolMaintenance == nil
    else { return }
    if let candidate, var record = try await taskStore.readTask(candidate.id),
      record.revision == candidate.revision,
      record.phase == .queued || record.phase == .waiting
    {
      var request = try codec.decode(GatewayStartRunRequest.self, from: record.request)
      if !record.instructions.isEmpty {
        request = continuationRequest(
          request,
          messages: request.initialMessages
            + record.instructions.map {
              Message(id: MessageID(rawValue: $0.id), role: .user, content: [.text($0.text)])
            })
      }
      record.instructions.removeAll()
      record.request = try codec.encode(request)
      record.runID = request.runID
      record.attemptCount += 1
      record.attemptPending = true
      record.phase = .running
      record.explanation = "Running attempt \(record.attemptCount)"
      taskDispatchReservation = request.runID
      defer { taskDispatchReservation = nil }
      _ = try await taskStore.saveTask(record)
      try Task.checkCancellation()
      // Synchronous admission cannot race another actor message after the ownership checks.
      let response = try startAdmittedRun(request)
      if case .busy = response.disposition {
        throw taskFailure("Another run acquired the worker during task admission.")
      }
    } else if let wakeDate {
      taskWake = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(max(0.05, wakeDate.timeIntervalSinceNow))) } catch {
          return
        }
        await self?.wakeTaskScheduler()
      }
    }
  }

  func continuationRequest(
    _ source: GatewayStartRunRequest, messages: [Message],
    artifacts: [ArtifactReference]? = nil
  ) -> GatewayStartRunRequest {
    let hasResults = messages.contains { message in
      message.content.contains {
        if case .toolResult = $0 { return true }
        return false
      }
    }
    let toolChoice: ToolChoice =
      source.toolChoice == .none ? .none : (hasResults ? .automatic : source.toolChoice)
    return GatewayStartRunRequest(
      runID: AgentRunID(), modelID: source.modelID,
      initialMessages: messages, options: source.options, toolChoice: toolChoice,
      workingDirectory: source.workingDirectory,
      availableArtifacts: artifacts ?? source.availableArtifacts,
      authorizationMode: source.authorizationMode)
  }
}
