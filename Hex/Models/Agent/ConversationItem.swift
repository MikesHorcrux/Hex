import Foundation

nonisolated struct ConversationItem: Codable, Identifiable, Equatable, Sendable {
  nonisolated enum Role: String, Codable, Sendable {
    case user
    case assistant
    case tool
    case event

    var label: String {
      switch self {
      case .user:
        "You"
      case .assistant:
        "Hex"
      case .tool:
        "Tool"
      case .event:
        "Run"
      }
    }
  }

  let id: UUID
  let role: Role
  var text: String
  let timestamp: Date
  var isStreaming: Bool

  init(
    id: UUID = UUID(),
    role: Role,
    text: String,
    timestamp: Date = Date(),
    isStreaming: Bool = false
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.timestamp = timestamp
    self.isStreaming = isStreaming
  }
}
