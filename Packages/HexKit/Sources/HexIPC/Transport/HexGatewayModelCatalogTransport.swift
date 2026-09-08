import HexCore

/// Optional catalog operation bound to the current authenticated local gateway session.
public protocol HexGatewayModelCatalogTransport: Sendable {
  func availableModels(lease: GatewayTransportConnectionLease) async throws -> [ModelDescriptor]
}
