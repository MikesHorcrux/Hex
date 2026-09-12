import Foundation

extension HexGatewayClient {
  /// A bounded metadata read only; this never admits a run or changes live replay acknowledgements.
  public func listHeartbeatRuns(_ request: GatewayHeartbeatRunListRequest) async throws
    -> GatewayHeartbeatRunPage
  {
    try Task.checkCancellation()
    let request = try request.validated()
    let connection = try requireConnectedGeneration()
    guard let connectedProtocolVersion,
      connectedProtocolVersion >= GatewayProtocolVersion(major: 1, minor: 11)
    else {
      throw GatewayFailure(
        code: .transportUnavailable,
        message:
          "Update the resident agent to read scheduled run history. The current connection uses an older protocol."
      )
    }
    guard let control = transport as? any HexGatewayResidentControlTransport else {
      throw GatewayFailure(
        code: .transportUnavailable,
        message: "The connected transport does not expose scheduled run history.")
    }
    do {
      let page = try await control.listHeartbeatRuns(request, lease: connection.lease)
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      let codec = GatewayWireCodec(configuration: configuration)
      let validated = try codec.roundTrip(page).validated(for: request)
      _ = try codec.encode(
        GatewayXPCResponseEnvelope(
          operation: .listHeartbeatRuns,
          body: codec.encode(validated)))
      return validated
    } catch {
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      invalidateConnectionIfUnavailable(error, generationID: connection.generationID)
      throw error
    }
  }
}
