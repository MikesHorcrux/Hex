import Foundation
import HexCore

extension HexGatewayService {
  func reconcileTaskAttempt(_ input: AgentTaskRecord) async throws {
    guard let taskStore, let historyReader, let runID = input.runID else {
      throw AgentTaskStorageError.invalidRecord
    }
    var record = input
    let source = try codec.decode(GatewayStartRunRequest.self, from: record.request)
    var checkpoint = GatewayTaskCheckpoint()
    if let snapshot = try await historyReader.snapshot(for: runID) {
      var sequence: UInt64 = 0
      while sequence < snapshot.latestSequence {
        try Task.checkCancellation()
        let page = try await historyReader.records(
          for: runID, after: sequence,
          through: snapshot.latestSequence, limit: 128, maximumBytes: configuration.maximumWireBytes
        )
        guard !page.isEmpty else { throw AgentTaskStorageError.invalidRecord }
        for event in page {
          guard event.sequence == sequence + 1 else { throw AgentTaskStorageError.invalidRecord }
          try checkpoint.accept(event)
          sequence = event.sequence
        }
      }
      guard snapshot.terminalRecord != nil else {
        throw AgentTaskStorageError.invalidRecord
      }
    }
    record.attemptPending = false
    if record.phase == .cancelling {
      do {
        try checkpoint.finish(reconciliation: nil)
        if checkpoint.messages.isEmpty { checkpoint.messages = source.initialMessages }
        var artifacts = source.availableArtifacts
        for item in checkpoint.artifacts where !artifacts.contains(item) { artifacts.append(item) }
        record.request = try codec.encode(
          continuationRequest(
            source,
            messages: checkpoint.messages, artifacts: artifacts))
        record.phase = .cancelled
        record.explanation = "Cancelled; dispatched work has been recorded"
      } catch AgentTaskStorageError.unavailable {
        record.phase = .blocked
        record.explanation =
          "Execution stopped. A tool has an uncertain outcome; inspect it before deciding what to do."
      }
    } else {
      do {
        try checkpoint.finish(reconciliation: record.reconciliation)
        if checkpoint.messages.isEmpty { checkpoint.messages = source.initialMessages }
        var artifacts = source.availableArtifacts
        for item in checkpoint.artifacts where !artifacts.contains(item) { artifacts.append(item) }
        record.request = try codec.encode(
          continuationRequest(
            source,
            messages: checkpoint.messages, artifacts: artifacts))
        record.reconciliation = nil
        switch checkpoint.terminal {
        case .runCompleted where record.instructions.isEmpty:
          record.phase = .completed
          record.explanation = "Completed"
        case _ where record.phase == .pausing:
          record.phase = .paused
          record.explanation = "Paused at a saved boundary"
        case .runFailed(let failure)
        where input.reconciliation == nil
          && !(failure.code == .invalidState
            && failure.message == "Run interrupted before reaching a terminal state."):
          if failure.isRetryable, checkpoint.started.isEmpty, record.retryCount < 3 {
            record.retryCount += 1
            record.phase = .waiting
            record.notBefore = Date().addingTimeInterval(pow(2, Double(record.retryCount)))
            record.explanation = "Waiting to retry a transient failure (\(record.retryCount)/3)"
          } else {
            record.phase = .blocked
            record.explanation = failure.message
          }
        default:
          if record.phase == .pausing {
            record.phase = .paused
            record.explanation = "Paused at a saved boundary"
          } else if record.retryCount >= 3 && input.reconciliation == nil {
            record.phase = .blocked
            record.explanation =
              "Repeated interruptions require your review before another attempt."
          } else {
            if record.phase == .running { record.retryCount += 1 }
            record.phase = .queued
            record.explanation = "Queued to continue from saved receipts"
          }
        }
      } catch AgentTaskStorageError.unavailable {
        record.phase = .blocked
        record.explanation =
          "A tool outcome is uncertain. Inspect the affected state and supply a reconciliation decision; Hex will not repeat it automatically."
      }
    }
    _ = try await taskStore.saveTask(record)
  }
}
