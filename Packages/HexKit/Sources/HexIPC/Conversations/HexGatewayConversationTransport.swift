import HexCore

public protocol HexGatewayConversationTransport: Sendable {
  func conversationStorage(
    _ request: ConversationStorageRequest,
    lease: GatewayTransportConnectionLease
  ) async throws -> ConversationStorageResponse
}
