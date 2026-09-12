import HexCore

extension HexGatewayClient {
  public func recoverRun(_ request: GatewayRunRecoveryRequest) async throws
    -> GatewayRunRecoveryResponse
  {
    try Task.checkCancellation()
    try GatewayRunRecoveryValidation.identity(request.runID.rawValue)
    let connection = try requireConnectedGeneration()
    guard let instanceID = gatewayInstanceID,
      let recovery = transport as? any HexGatewayRunRecoveryTransport
    else {
      throw GatewayFailure(
        code: .recoveryUnavailable,
        message: "This connection does not support read-only run recovery.")
    }
    do {
      let response = try await recovery.recoverRun(request, lease: connection.lease)
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      let validated = try GatewayWireCodec(configuration: configuration).roundTrip(response)
      try GatewayRunRecoveryValidation.response(
        validated, runID: request.runID, instanceID: instanceID)
      return validated
    } catch {
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      invalidateConnectionIfUnavailable(error, generationID: connection.generationID)
      throw error
    }
  }

  /// Reading never advances live acknowledgements. The app must apply and durably save this page
  /// before requesting the next page or explicitly restoring a live cursor.
  public func readRunHistory(_ request: GatewayRunHistoryRequest) async throws
    -> GatewayRunHistoryPage
  {
    try Task.checkCancellation()
    try GatewayRunRecoveryValidation.request(request)
    let connection = try requireConnectedGeneration()
    guard let instanceID = gatewayInstanceID,
      let recovery = transport as? any HexGatewayRunRecoveryTransport
    else {
      throw GatewayFailure(
        code: .recoveryUnavailable, message: "This connection does not support durable run history."
      )
    }
    do {
      let page = try await recovery.readRunHistory(request, lease: connection.lease)
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      let codec = GatewayWireCodec(configuration: configuration)
      let validated = try codec.roundTrip(page)
      _ = try codec.encode(
        GatewayXPCResponseEnvelope(operation: .readRunHistory, body: codec.encode(validated)))
      try GatewayRunRecoveryValidation.page(validated, request: request, instanceID: instanceID)
      return validated
    } catch {
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      invalidateConnectionIfUnavailable(error, generationID: connection.generationID)
      throw error
    }
  }
}
