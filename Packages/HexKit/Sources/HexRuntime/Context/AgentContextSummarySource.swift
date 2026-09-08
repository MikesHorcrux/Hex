import Foundation
import HexCore

/// Preserves chronological, whole user exchanges. An end-of-input boundary is supplied by the
/// caller's context plan; outstanding call/result pairs still make that boundary invalid.
struct AgentContextSummarySource: Sendable {
  let exchanges: [[Message]]

  init(
    messages: [Message], estimator: any AgentContextTokenEstimating,
    allowsToolBatchBoundaries: Bool = false
  ) throws {
    guard !messages.isEmpty, messages.count <= 4_096,
      messages.first?.role == .user
        || (allowsToolBatchBoundaries && messages.first?.role == .assistant)
    else {
      throw AgentContextSummarizationError.invalidHistory
    }
    let data: Data
    do { data = try JSONEncoder().encode(messages) } catch {
      throw AgentContextSummarizationError.invalidHistory
    }
    guard data.count <= 8 * 1_024 * 1_024 else {
      throw AgentContextSummarizationError.inputDoesNotFit
    }

    var messageIDs = Set<MessageID>()
    var callIDs = Set<ToolCallID>()
    var outstanding = Set<ToolCallID>()
    var groups: [[Message]] = []
    var current: [Message] = []
    for message in messages {
      try Task.checkCancellation()
      guard messageIDs.insert(message.id).inserted, !message.content.isEmpty else {
        throw AgentContextSummarizationError.invalidHistory
      }
      do {
        guard try estimator.estimateTokens(in: message) >= 0 else {
          throw AgentContextSummarizationError.invalidRequest
        }
      } catch AgentContextPlanningError.imageCostUnavailable {
        throw AgentContextSummarizationError.unestimatedImage
      } catch is CancellationError {
        throw CancellationError()
      } catch is AgentContextSummarizationError {
        throw AgentContextSummarizationError.invalidRequest
      } catch {
        throw AgentContextSummarizationError.invalidHistory
      }
      switch message.role {
      case .system, .developer:
        throw AgentContextSummarizationError.invalidHistory
      case .user:
        guard outstanding.isEmpty else { throw AgentContextSummarizationError.invalidHistory }
        if !current.isEmpty {
          groups.append(current)
          current = []
        }
      case .assistant:
        guard outstanding.isEmpty else { throw AgentContextSummarizationError.invalidHistory }
      case .tool:
        break
      }
      for content in message.content {
        switch content {
        case .text, .image:
          guard message.role == .user || message.role == .assistant else {
            throw AgentContextSummarizationError.invalidHistory
          }
        case .toolCall(let call):
          guard message.role == .assistant,
            call.id.rawValue.contains(where: { !$0.isWhitespace }),
            call.name.contains(where: { !$0.isWhitespace }), callIDs.insert(call.id).inserted
          else { throw AgentContextSummarizationError.invalidHistory }
          outstanding.insert(call.id)
        case .toolResult(let result):
          guard message.role == .tool, outstanding.remove(result.toolCallID) != nil else {
            throw AgentContextSummarizationError.invalidHistory
          }
        }
      }
      current.append(message)
      if allowsToolBatchBoundaries && message.role == .tool && outstanding.isEmpty {
        groups.append(current)
        current = []
      }
    }
    guard outstanding.isEmpty else { throw AgentContextSummarizationError.invalidHistory }
    if !current.isEmpty { groups.append(current) }
    exchanges = groups
  }
}
