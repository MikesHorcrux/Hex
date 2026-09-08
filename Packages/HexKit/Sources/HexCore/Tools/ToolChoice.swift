public enum ToolChoice: Codable, Equatable, Sendable {
  case automatic
  case none
  case required
  case named(String)
}
