import Foundation

nonisolated struct AgentConversationArchive: Codable, Equatable, Sendable {
  static let currentSchemaVersion: UInt16 = 1

  let schemaVersion: UInt16
  let selectedConversationID: UUID?
  let conversations: [AgentConversation]

  init(
    selectedConversationID: UUID?,
    conversations: [AgentConversation],
    schemaVersion: UInt16 = AgentConversationArchive.currentSchemaVersion
  ) {
    self.schemaVersion = schemaVersion
    self.selectedConversationID = selectedConversationID
    self.conversations = conversations
  }
}
