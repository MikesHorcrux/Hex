public struct HexGatewayPermissionManagementHandlers: Sendable {
  public let inbox: (@Sendable () async throws -> GatewayApprovalInbox)?
  public let revoke: (@Sendable (GatewaySessionGrant) async throws -> GatewayApprovalInbox)?
  public let folder: (@Sendable () async throws -> GatewayFolderAccessStatus)?

  public init(
    inbox: (@Sendable () async throws -> GatewayApprovalInbox)? = nil,
    revoke: (@Sendable (GatewaySessionGrant) async throws -> GatewayApprovalInbox)? = nil,
    folder: (@Sendable () async throws -> GatewayFolderAccessStatus)? = nil
  ) {
    self.inbox = inbox
    self.revoke = revoke
    self.folder = folder
  }

  public static let unavailable = Self()
}
