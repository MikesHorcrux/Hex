import Foundation
import HexCore

/// Reconstructs only proven journal facts. Original records are never modified by continuation.
struct GatewayTaskCheckpoint {
  var messages: [Message] = []
  var calls: [ToolCallID: ToolCall] = [:]
  var started: Set<ToolCallID> = []
  var results: [ToolCallID: ToolResult] = [:]
  var terminal: AgentEvent?
  var artifacts: [ArtifactReference] = []

  mutating func accept(_ record: AgentEventRecord) throws {
    switch record.event {
    case .messageAppended(let message):
      if !messages.contains(where: { $0.id == message.id }) { messages.append(message) }
      for content in message.content {
        if case .toolCall(let call) = content { calls[call.id] = call }
      }
    case .toolStarted(let call):
      started.insert(call.id)
      calls[call.id] = call
    case .toolFinished(let result):
      results[result.toolCallID] = result
      for artifact in result.artifacts where !artifacts.contains(artifact) {
        artifacts.append(artifact)
      }
    case .contextCompacted(let compaction):
      let sources = Set(compaction.sourceMessageIDs)
      let matching = messages.filter { sources.contains($0.id) }.map(\.id)
      guard matching == compaction.sourceMessageIDs,
        let first = messages.firstIndex(where: { sources.contains($0.id) })
      else {
        throw AgentTaskStorageError.invalidRecord
      }
      messages.removeAll { sources.contains($0.id) }
      messages.insert(compaction.summaryMessage, at: first)
    case .runCompleted, .runCancelled, .runFailed: terminal = record.event
    default: break
    }
  }

  var hasUncertainEffects: Bool {
    started.contains { id in
      guard let result = results[id] else { return true }
      return result.requiresUserAttention
        || (result.status == .failure && result.notExecutedReason == nil
          && result.executionOutcome != .completed)
    } || results.values.contains(where: \.requiresUserAttention)
  }

  mutating func finish(reconciliation: String?) throws {
    if hasUncertainEffects, reconciliation == nil { throw AgentTaskStorageError.unavailable }
    let presentResults = Set(
      messages.flatMap(\.content).compactMap { content -> ToolCallID? in
        if case .toolResult(let result) = content { return result.toolCallID }
        return nil
      })
    // Only calls still present in active context need a paired result. Compacted batches already
    // have a validated summary and retain their exact original receipts in the journal.
    let activeCalls = messages.flatMap(\.content).compactMap { content -> ToolCall? in
      if case .toolCall(let call) = content { return call }
      return nil
    }
    for call in activeCalls where !presentResults.contains(call.id) {
      let result: ToolResult
      if let known = results[call.id] {
        result = known
      } else if let reconciliation {
        result = ToolResult(
          toolCallID: call.id, status: .failure,
          output: .object([
            "outcome": .string("user_reconciled_unknown_outcome"),
            "user_observation": .string(reconciliation),
          ]))
      } else {
        // An announced call without a durable non-execution or execution receipt is not safe.
        throw AgentTaskStorageError.unavailable
      }
      messages.append(Message(role: .tool, content: [.toolResult(result)]))
    }
    if let reconciliation {
      messages.append(
        Message(
          role: .user,
          content: [
            .text(
              "My reconciliation decision for the interrupted attempt: " + reconciliation)
          ]))
    }
  }
}
