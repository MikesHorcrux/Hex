import Foundation
import HexCore

extension AgentConversation {
  nonisolated static let maximumContextMessages = 24
  nonisolated static let maximumContextBytes = 24 * 1_024
  nonisolated static let maximumPromptBytes = 128 * 1_024
  nonisolated static let maximumPersistedTextBytes = 64 * 1_024

  func boundedContextMessages(
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

      selected.append(Message(role: role, content: [.text(text)]))
      remainingBytes -= text.utf8.count
      if remainingBytes == 0 {
        break
      }
    }

    return selected.reversed()
  }

  private static func prefix(_ text: String, maximumBytes: Int) -> String {
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
