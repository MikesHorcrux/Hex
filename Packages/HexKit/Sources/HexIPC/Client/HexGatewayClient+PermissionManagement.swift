extension HexGatewayClient {
  public func approvalInbox() async throws -> GatewayApprovalInbox {
    try await permissionManagement { try await $0.approvalInbox(lease: $1).validated() }
  }

  public func revokeSessionGrant(_ grant: GatewaySessionGrant) async throws -> GatewayApprovalInbox
  {
    _ = try grant.validated()
    return try await permissionManagement {
      try await $0.revokeSessionGrant(grant, lease: $1).validated()
    }
  }

  public func folderAccessStatus() async throws -> GatewayFolderAccessStatus {
    try await permissionManagement { try await $0.folderAccessStatus(lease: $1).validated() }
  }

  private func permissionManagement<Response: Sendable>(
    _ operation:
      @Sendable (
        any HexGatewayPermissionManagementTransport, GatewayTransportConnectionLease
      ) async throws -> Response
  ) async throws -> Response {
    try Task.checkCancellation()
    let connection = try requireConnectedGeneration()
    guard let permissionTransport = transport as? any HexGatewayPermissionManagementTransport else {
      throw GatewayFailure(
        code: .transportUnavailable,
        message: "Restart Hex Agent to manage permissions with this app.")
    }
    do {
      let result = try await operation(permissionTransport, connection.lease)
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      return result
    } catch {
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      invalidateConnectionIfUnavailable(error, generationID: connection.generationID)
      throw error
    }
  }
}
