public protocol HexGatewayPermissionManagementTransport: Sendable {
  func approvalInbox(lease: GatewayTransportConnectionLease) async throws -> GatewayApprovalInbox
  func revokeSessionGrant(_ grant: GatewaySessionGrant, lease: GatewayTransportConnectionLease)
    async throws -> GatewayApprovalInbox
  func folderAccessStatus(lease: GatewayTransportConnectionLease) async throws
    -> GatewayFolderAccessStatus
}
