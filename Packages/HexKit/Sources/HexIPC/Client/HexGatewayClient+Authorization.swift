import HexCore

extension HexGatewayClient {
  /// Sends an exact interactive authorization response through a transport that supports the
  /// resident gateway boundary. The connection generation is checked again after the await so a
  /// response from an old app session cannot affect a newer connection.
  public func submitAuthorizationDecision(
    _ request: AuthorizationRequest,
    choice: GatewayAuthorizationDecisionChoice
  ) async throws {
    try Task.checkCancellation()
    let connection = try requireConnectedGeneration()
    guard let authorizationTransport = transport as? any HexGatewayAuthorizationDecisionTransport
    else {
      throw GatewayFailure(
        code: .transportUnavailable,
        message: "The connected gateway transport does not support authorization responses."
      )
    }

    do {
      try await authorizationTransport.submitAuthorizationDecision(
        request,
        choice: choice,
        lease: connection.lease
      )
    } catch {
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      invalidateConnectionIfUnavailable(error, generationID: connection.generationID)
      throw error
    }

    try Task.checkCancellation()
    try requireCurrentConnectedGeneration(connection.generationID)
  }
}
