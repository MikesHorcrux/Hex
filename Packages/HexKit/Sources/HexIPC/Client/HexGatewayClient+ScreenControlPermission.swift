extension HexGatewayClient {
  /// Reads screen-control permission state from the currently connected resident gateway. This
  /// method never opens a connection; callers must connect through this client first.
  public func screenControlPermissionStatus() async throws
    -> GatewayScreenControlPermissionStatus
  {
    try await performScreenControlPermissionOperation { transport, lease in
      try await transport.screenControlPermissionStatus(lease: lease)
    }
  }

  /// Asks the resident gateway to request the screen-control tool's macOS permissions. The returned
  /// value is the immediate post-request state and is granted only when both required grants are
  /// present.
  public func requestScreenControlPermission() async throws
    -> GatewayScreenControlPermissionStatus
  {
    try await performScreenControlPermissionOperation { transport, lease in
      try await transport.requestScreenControlPermission(lease: lease)
    }
  }

  private func performScreenControlPermissionOperation(
    _ operation:
      @Sendable (
        any HexGatewayScreenControlPermissionTransport,
        GatewayTransportConnectionLease
      ) async throws -> GatewayScreenControlPermissionStatus
  ) async throws -> GatewayScreenControlPermissionStatus {
    try Task.checkCancellation()
    let connection = try requireConnectedGeneration()
    let permissionTransport = try screenControlPermissionTransport()

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

  private func screenControlPermissionTransport() throws
    -> any HexGatewayScreenControlPermissionTransport
  {
    guard
      let permissionTransport = transport as? any HexGatewayScreenControlPermissionTransport
    else {
      throw GatewayFailure(
        code: .transportUnavailable,
        message:
          "The connected gateway transport does not support screen-control permission controls."
      )
    }
    return permissionTransport
  }
}
