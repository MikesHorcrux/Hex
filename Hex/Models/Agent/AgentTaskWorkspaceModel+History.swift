import Foundation
import HexCore
import HexIPC

extension AgentTaskWorkspaceModel {
  func readSelectedAttempt() async throws {
    guard let selected, let runID = historicalRunID ?? selected.runID else { return }
    if observedRunID != runID {
      observedRunID = runID
      sequence = 0
      hasInference = false
      items = []
      approvals = []
      observationGeneration = UUID()
    }
    let generation = observationGeneration
    let response = try await client.recoverRun(.init(runID: runID))
    guard generation == observationGeneration else { return }
    let snapshot: GatewayJournalRunSnapshot?
    switch response.disposition {
    case .resident(_, _, let journal): snapshot = journal
    case .journaled(let journal): snapshot = journal
    case .unknown: snapshot = nil
    }
    guard let snapshot else { return }
    // Bounded catch-up per poll keeps controls responsive even with a large prior attempt.
    for _ in 0..<8 where sequence < snapshot.latestSequence {
      let page = try await client.readRunHistory(
        .init(
          runID: runID,
          firstEventID: snapshot.firstEventID, afterSequence: sequence,
          throughSequence: snapshot.latestSequence, limit: 32))
      guard generation == observationGeneration else { return }
      for record in page.records {
        guard record.sequence == sequence + 1 else {
          throw GatewayFailure(code: .invalidEventSequence, message: "Task history has a gap.")
        }
        applyTaskRecord(record)
        sequence = record.sequence
      }
      if page.records.isEmpty { break }
    }
  }

  func applyTaskRecord(_ record: AgentEventRecord) {
    switch record.event {
    case .runStarted:
      if inspectingHistory { items.append(ConversationItem(role: .event, text: "Attempt started")) }
    case .inferenceRequested:
      hasInference = true
      if inspectingHistory {
        items.append(ConversationItem(role: .event, text: "Inference requested"))
      }
    case .messageAppended(let message)
    where (hasInference || inspectingHistory)
      && (message.role == .assistant || (inspectingHistory && message.role == .user)):
      let text = message.content.compactMap { part -> String? in
        if case .text(let text) = part { return text }
        return nil
      }.joined(separator: "\n")
      if !text.isEmpty {
        items.append(
          ConversationItem(
            id: message.id.rawValue, role: message.role == .user ? .user : .assistant,
            text: text, timestamp: record.timestamp))
      }
    case .toolStarted(let call):
      items.append(
        ConversationItem(
          id: record.id.rawValue, role: .tool,
          text: "Started " + call.name, timestamp: record.timestamp))
    case .toolFinished(let result):
      items.append(
        ConversationItem(
          id: record.id.rawValue, role: .tool,
          text: HexJSONValueFormatter.string(from: result.output), timestamp: record.timestamp,
          artifacts: result.artifacts, toolCallID: result.toolCallID))
    case .authorizationRequested(let request):
      if !approvals.contains(where: { $0.id == request.id }) { approvals.append(request) }
    case .authorizationDecided(let id, _): approvals.removeAll { $0.id == id }
    case .runCompleted, .runCancelled, .runFailed: approvals = []
    default: break
    }
    if items.count > 100 { items.removeFirst(items.count - 100) }
  }
}
