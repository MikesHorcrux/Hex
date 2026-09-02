import Foundation

nonisolated struct AgentConversation: Codable, Equatable, Identifiable, Sendable {
  static let defaultTitle = "New conversation"

  let id: UUID
  var title: String
  let createdAt: Date
  var updatedAt: Date
  var transcript: [ConversationItem]

  init(
    id: UUID = UUID(),
    title: String = AgentConversation.defaultTitle,
    createdAt: Date = Date(),
    updatedAt: Date? = nil,
    transcript: [ConversationItem] = []
  ) {
    self.id = id
    self.title = title
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
    self.transcript = transcript
  }

  mutating func recordPrompt(_ prompt: String, at date: Date = Date()) {
    if title == Self.defaultTitle {
      title = Self.title(for: prompt)
    }
    updatedAt = max(date, createdAt)
  }

  static func title(for prompt: String) -> String {
    let normalized =
      prompt
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    guard !normalized.isEmpty else {
      return defaultTitle
    }
    let limit = 48
    if normalized.count <= limit {
      return normalized
    }
    return String(normalized.prefix(limit - 1)) + "…"
  }
}
