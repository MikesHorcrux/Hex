import Foundation
import HexCore

nonisolated protocol AgentPagedConversationStoring: AgentConversationStoring {
  func saveChanges(_ conversations: [AgentConversation], selected: UUID?) async throws
  func readConversation(_ id: UUID) async throws -> AgentConversation
  func earlierTranscript(_ id: UUID, before: Int64?) async throws
    -> (items: [ConversationItem], before: Int64?)
  func listConversations(_ query: ConversationStorageRequest.Query) async throws
    -> (conversations: [AgentConversation], next: ConversationStorageRequest.Cursor?)
  func removeConversation(_ id: UUID) async throws
}
