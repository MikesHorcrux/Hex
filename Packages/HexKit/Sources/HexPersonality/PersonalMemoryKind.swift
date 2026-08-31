public enum PersonalMemoryKind: String, Codable, CaseIterable, Sendable {
  case preference
  case fact
  case relationship
  case projectContext
}
