/// The resident persistence owner implements this boundary; clients never open its database.
public protocol ConversationStorage: Sendable {
  func conversationStorage(_ request: ConversationStorageRequest) async throws
    -> ConversationStorageResponse
}
