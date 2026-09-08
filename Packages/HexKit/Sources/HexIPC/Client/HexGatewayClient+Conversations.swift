import HexCore

extension HexGatewayClient: ConversationStorage {
  public func conversationStorage(_ request: ConversationStorageRequest) async throws
    -> ConversationStorageRequest.Response
  {
    try Task.checkCancellation()
    let connection = try requireConnectedGeneration()
    guard let transport = transport as? any HexGatewayConversationTransport else {
      throw GatewayFailure(
        code: .recoveryUnavailable, message: "Conversation storage is unavailable.")
    }
    do {
      let response = try await transport.conversationStorage(request, lease: connection.lease)
      try requireCurrentConnectedGeneration(connection.generationID)
      let validated = try GatewayWireCodec(configuration: configuration).roundTrip(response)
      if let failure = validated.failure { throw failure }
      return validated
    } catch {
      try requireCurrentConnectedGeneration(connection.generationID)
      invalidateConnectionIfUnavailable(error, generationID: connection.generationID)
      throw error
    }
  }
}
