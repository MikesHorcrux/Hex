extension HexGatewayClient {
  /// Reads Accessibility trust from the currently connected resident gateway. This method never
  /// opens a connection; callers must connect through this client first.
  public func accessibilityPermissionStatus() async throws
    -> GatewayAccessibilityPermissionStatus
  {
    try await performAccessibilityPermissionOperation { transport, lease in
      try await transport.accessibilityPermissionStatus(lease: lease)
    }
  }

  /// Asks the resident gateway to request Accessibility from macOS. The returned value is the
  /// immediate post-request state and must not be interpreted as granted when it is `.notTrusted`.
  public func requestAccessibilityPermission() async throws
    -> GatewayAccessibilityPermissionStatus
  {
    try await performAccessibilityPermissionOperation { transport, lease in
      try await transport.requestAccessibilityPermission(lease: lease)
    }
  }

  private func performAccessibilityPermissionOperation(
    _ operation:
      @Sendable (
        any HexGatewayAccessibilityPermissionTransport,
        GatewayTransportConnectionLease
      ) async throws -> GatewayAccessibilityPermissionStatus
  ) async throws -> GatewayAccessibilityPermissionStatus {
    try Task.checkCancellation()
    let connection = try requireConnectedGeneration()
    let permissionTransport = try accessibilityPermissionTransport()

    do {
      let status = try await operation(permissionTransport, connection.lease)
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      return status
    } catch {
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      invalidateConnectionIfUnavailable(error, generationID: connection.generationID)
      throw error
    }
  }

  private func accessibilityPermissionTransport() throws
    -> any HexGatewayAccessibilityPermissionTransport
  {
    guard
      let permissionTransport = transport as? any HexGatewayAccessibilityPermissionTransport
    else {
      throw GatewayFailure(
        code: .transportUnavailable,
        message:
          "The connected gateway transport does not support Accessibility permission controls."
      )
    }
    return permissionTransport
  }
}
