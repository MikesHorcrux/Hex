import HexIPC

extension HexGatewayClientAdapter: HexPermissionManaging {
  func approvalInbox() async throws -> GatewayApprovalInbox { try await client.approvalInbox() }

  func revokeSessionGrant(_ grant: GatewaySessionGrant) async throws -> GatewayApprovalInbox {
    try await client.revokeSessionGrant(grant)
  }

  func folderAccessStatus() async throws -> GatewayFolderAccessStatus {
    try await client.folderAccessStatus()
  }
}
