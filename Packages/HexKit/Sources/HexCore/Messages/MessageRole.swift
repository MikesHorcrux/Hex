public enum MessageRole: String, Codable, CaseIterable, Sendable {
  case system
  case developer
  case user
  case assistant
  case tool
}
