public enum MCPProtocolVersion: String, CaseIterable, Sendable {
  case november2024 = "2024-11-05"
  case march2025 = "2025-03-26"
  case june2025 = "2025-06-18"
  case november2025 = "2025-11-25"

  public static let preferred = MCPProtocolVersion.november2025
}
