import Foundation
import HexCore

nonisolated enum ConversationItemRole: String, Codable, Sendable {
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
