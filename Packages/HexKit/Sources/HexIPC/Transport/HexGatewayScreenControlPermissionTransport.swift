/// Optional transport capability for querying and requesting the screen-control tool's macOS
/// permissions in the resident gateway process. Every call is bound to the authenticated
/// connection lease owned by the client.
public protocol HexGatewayScreenControlPermissionTransport: Sendable {
  func screenControlPermissionStatus(
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayScreenControlPermissionStatus

  func requestScreenControlPermission(
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayScreenControlPermissionStatus
}
