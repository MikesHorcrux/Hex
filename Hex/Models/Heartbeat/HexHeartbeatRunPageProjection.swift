import Foundation
import HexCore

/// Projects only the selected bounded page. No live acknowledgements or conversation mutations.
nonisolated struct HexHeartbeatRunPageProjection {
  let items: [ConversationItem]
  let hasPartialAssistantText: Bool

  init(records: [AgentEventRecord]) {
    var rows: [ConversationItem] = []
    var streamingIndex: Int?
    var finishedCalls = Set<ToolCallID>()
    var partialRows = Set<UUID>()
    for record in records {
      func row(
        _ role: ConversationItem.Role, _ text: String,
        artifacts: [ArtifactReference] = [], callID: ToolCallID? = nil
      ) -> ConversationItem {
        ConversationItem(
          id: record.id.rawValue, role: role, text: text,
          timestamp: record.timestamp, artifacts: artifacts, toolCallID: callID)
      }
      switch record.event {
      case .inferenceEvent(.started):
        streamingIndex = nil
      case .inferenceEvent(.textDelta(let text)):
        guard !text.isEmpty else { continue }
        if let index = streamingIndex {
          rows[index].text += text
        } else {
          rows.append(row(.assistant, text))
          streamingIndex = rows.count - 1
          partialRows.insert(record.id.rawValue)
        }
      case .messageAppended(let message):
        let results = message.content.compactMap { part -> ToolResult? in
          if case .toolResult(let result) = part { return result }
          return nil
        }
        if message.role == .tool, !results.isEmpty {
          let unseen = results.filter { !finishedCalls.contains($0.toolCallID) }
          guard !unseen.isEmpty else { continue }
          rows.append(
            row(
              .tool, unseen.map(AgentMessagePresentation.toolResultText).joined(separator: "\n"),
              artifacts: unseen.flatMap(\.artifacts),
              callID: unseen.count == 1 ? unseen.first?.toolCallID : nil))
          finishedCalls.formUnion(unseen.map(\.toolCallID))
          continue
        }
        let text = AgentMessagePresentation.text(message)
        guard !text.isEmpty else { continue }
        switch message.role {
        case .assistant:
          if let index = streamingIndex {
            rows[index].text = text
            partialRows.remove(rows[index].id)
            streamingIndex = nil
          } else {
            rows.append(row(.assistant, text))
          }
        case .user: rows.append(row(.user, text))
        case .tool: rows.append(row(.tool, text))
        case .system, .developer: break
        }
      case .toolStarted(let call): rows.append(row(.tool, "Started \(call.name)"))
      case .toolFinished(let result):
        guard finishedCalls.insert(result.toolCallID).inserted else { continue }
        rows.append(
          row(
            .tool, AgentMessagePresentation.toolResultText(result),
            artifacts: result.artifacts, callID: result.toolCallID))
      case .authorizationRequested(let request):
        rows.append(
          row(
            .event,
            "Approval requested · \(request.explanation)\n\(request.capability.rawValue) · \(request.operation)\n\(request.resource ?? "No specific target")\nAnswer live requests in the Approval inbox. Historical requests cannot be replayed."
          ))
      case .authorizationDecided(_, let decision):
        switch decision {
        case .allow: rows.append(row(.event, "Approval granted."))
        case .deny(let reason):
          rows.append(row(.event, reason.map { "Approval denied · \($0)" } ?? "Approval denied."))
        }
      case .runCompleted: rows.append(row(.event, "Run completed."))
      case .runCancelled: rows.append(row(.event, "Run cancelled."))
      case .runFailed(let failure): rows.append(row(.event, "Run failed · \(failure.message)"))
      default: break
      }
    }
    items = rows
    hasPartialAssistantText = !partialRows.isEmpty
  }
}
