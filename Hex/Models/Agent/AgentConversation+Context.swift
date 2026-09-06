import Foundation
import HexCore

extension AgentConversation {
  nonisolated static let maximumContextMessages = 24
  nonisolated static let maximumContextBytes = 24 * 1_024
  nonisolated static let maximumPersistedTextBytes = 64 * 1_024
  nonisolated static let maximumPromptBytes = maximumPersistedTextBytes

  /// Native messages are the source of inference context; display rows are only a legacy fallback.
  /// A migration cannot recover tool arguments, images or IDs that older versions never saved.
  nonisolated func resolvedHistory() -> AgentConversationHistory {
    history
      ?? AgentConversationHistory(
        legacyMessages: transcript.compactMap { item in
          guard !item.isStreaming, !item.text.isEmpty else { return nil }
          let role: MessageRole
          switch item.role {
          case .user: role = .user
          case .assistant: role = .assistant
          case .tool, .event: return nil
          }
          return Message(id: MessageID(rawValue: item.id), role: role, content: [.text(item.text)])
        })
  }

  /// Keep whole exchanges and stable identities. Compaction must be an explicit, provenance-bearing
  /// operation, not arbitrary clipping of this projection. Superseded retry attempts stay on disk.
  nonisolated func contextMessages() -> [Message] {
    let history = resolvedHistory()
    // Admission and archive loading reject malformed metadata. If in-memory state is incomplete,
    // retain raw context instead of hiding messages behind a summary with unverified provenance.
    return (try? AgentConversationContextProjection.messages(in: history))
      ?? AgentConversationContextProjection.uncompactedMessages(in: history)
  }

  nonisolated var hasContextToolIdentityCollision: Bool {
    var identities = Set<ToolCallID>()
    for content in contextMessages().flatMap(\.content) {
      if case .toolCall(let call) = content, !identities.insert(call.id).inserted { return true }
    }
    return false
  }

  nonisolated var hasUnresolvedHistory: Bool {
    guard let history else { return false }
    let superseded = Set(history.exchanges.compactMap(\.retryOfRunID))
    return history.exchanges.filter { !superseded.contains($0.runID) }.contains { exchange in
      if exchange.outcome == .inProgress || exchange.outcome == .interrupted { return true }
      var outstanding = Set<ToolCallID>()
      for content in exchange.messages.flatMap(\.content) {
        switch content {
        case .toolCall(let call): outstanding.insert(call.id)
        case .toolResult(let result): outstanding.remove(result.toolCallID)
        case .text, .image: break
        }
      }
      return !outstanding.isEmpty
    }
  }

  nonisolated func boundedContextMessages(
    maximumMessages: Int = AgentConversation.maximumContextMessages,
    maximumBytes: Int = AgentConversation.maximumContextBytes
  ) -> [Message] {
    guard maximumMessages > 0, maximumBytes > 0 else {
      return []
    }

    var remainingBytes = maximumBytes
    var selected: [Message] = []
    selected.reserveCapacity(min(maximumMessages, transcript.count))

    for item in transcript.reversed() {
      guard selected.count < maximumMessages else {
        break
      }

      let role: MessageRole
      switch item.role {
      case .user:
        role = .user
      case .assistant:
        role = .assistant
      case .tool, .event:
        continue
      }

      let text = Self.prefix(
        item.text, maximumBytes: min(remainingBytes, Self.maximumPersistedTextBytes))
      guard !text.isEmpty else {
        break
      }

      selected.append(Message(id: MessageID(rawValue: item.id), role: role, content: [.text(text)]))
      remainingBytes -= text.utf8.count
      if remainingBytes == 0 {
        break
      }
    }

    return selected.reversed()
  }

  private nonisolated static func prefix(_ text: String, maximumBytes: Int) -> String {
    guard maximumBytes > 0 else {
      return ""
    }
    guard text.utf8.count > maximumBytes else {
      return text
    }
    var bytes = Array(text.utf8.prefix(maximumBytes))
    while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil {
      bytes.removeLast()
    }
    return String(decoding: bytes, as: UTF8.self)
  }
}
