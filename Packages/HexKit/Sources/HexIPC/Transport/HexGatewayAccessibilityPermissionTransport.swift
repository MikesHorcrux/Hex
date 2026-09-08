/// Optional transport capability for querying and requesting Accessibility in the resident
/// gateway process. Every call is bound to the authenticated connection lease owned by the client.
public protocol HexGatewayAccessibilityPermissionTransport: Sendable {
  func accessibilityPermissionStatus(
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayAccessibilityPermissionStatus

  func requestAccessibilityPermission(
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayAccessibilityPermissionStatus
}
