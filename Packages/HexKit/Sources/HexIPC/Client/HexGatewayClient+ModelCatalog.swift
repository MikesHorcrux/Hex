import HexCore

extension HexGatewayClient {
  public func availableModels() async throws -> [ModelDescriptor] {
    try Task.checkCancellation()
    let connection = try requireConnectedGeneration()
    guard let transport = transport as? any HexGatewayModelCatalogTransport else {
      throw GatewayFailure(code: .transportUnavailable, message: "Model discovery is unavailable.")
    }
    do {
      let models = try await transport.availableModels(lease: connection.lease)
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      return models
    } catch {
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      invalidateConnectionIfUnavailable(error, generationID: connection.generationID)
      throw error
    }
  }
}
