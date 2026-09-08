/// Optional, session-bound read-only access to immutable output already stored by the resident.
public protocol HexGatewayArtifactReadTransport: Sendable {
  func readArtifact(_ request: GatewayArtifactReadRequest, lease: GatewayTransportConnectionLease)
    async throws -> GatewayArtifactReadResponse
}
