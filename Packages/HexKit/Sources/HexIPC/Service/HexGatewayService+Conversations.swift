import HexCore

extension HexGatewayService {
  public func conversationStorage(
    _ untrusted: ConversationStorageRequest,
    sessionID: GatewaySessionID
  ) async throws -> ConversationStorageResponse {
    try Task.checkCancellation()
    let request = try codec.roundTrip(untrusted)
    try requireSession(sessionID)
    guard let conversationStore else {
      throw GatewayFailure(
        code: .recoveryUnavailable, message: "Conversation storage is unavailable.")
    }
    var response: ConversationStorageResponse
    do { response = try await conversationStore.conversationStorage(request) } catch let failure
      as ConversationStorageFailure
    {
      response = .init()
      response.failure = failure
    } catch {
      try requireSession(sessionID)
      throw GatewayFailure(
        code: .recoveryUnavailable,
        message:
          "Conversation storage could not complete the operation. Saved history was retained.")
    }
    // A write may have committed before a disconnection. Its stable operation ID permits a retry.
    try requireSession(sessionID)
    _ = try codec.encode(
      GatewayXPCResponseEnvelope(
        operation: .conversationStorage,
        body: codec.encode(response)))
    return try codec.roundTrip(response)
  }
}
