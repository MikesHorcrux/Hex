import Foundation

public enum ConversationStorageEntryKind: String, Codable, Sendable {
  case display, message, exchange, compaction
}
