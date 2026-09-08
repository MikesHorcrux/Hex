import HexIPC

nonisolated protocol HexPermissionManaging: Sendable {
  func approvalInbox() async throws -> GatewayApprovalInbox
  func revokeSessionGrant(_ grant: GatewaySessionGrant) async throws -> GatewayApprovalInbox
  func folderAccessStatus() async throws -> GatewayFolderAccessStatus
}
