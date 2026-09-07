import HexCapabilities
import HexCore
import HexIPC

/// Reads live authority from its owners. It never reconstructs an actionable approval from history.
public actor HexGatewayPermissionManager {
  private let broker: HexGatewayAuthorizationBroker
  private let center: CapabilityAuthorizationCenter
  private let defaultMode: HexAuthorizationMode
  private let folderProbe: HexGatewayFolderAccessProbe

  public init(
    broker: HexGatewayAuthorizationBroker, center: CapabilityAuthorizationCenter,
    defaultMode: HexAuthorizationMode, folderProbe: HexGatewayFolderAccessProbe
  ) {
    self.broker = broker
    self.center = center
    self.defaultMode = defaultMode
    self.folderProbe = folderProbe
  }

  public func inbox() async throws -> GatewayApprovalInbox {
    try Task.checkCancellation()
    let grants = await center.sessionGrantKeys().map {
      GatewaySessionGrant(
        sessionID: center.sessionID.rawValue, capability: $0.capability,
        operation: $0.operation, resource: $0.resource)
    }.sorted {
      [$0.capability.rawValue, $0.operation, $0.resource ?? ""]
        .lexicographicallyPrecedes([$1.capability.rawValue, $1.operation, $1.resource ?? ""])
    }
    return try await GatewayApprovalInbox(
      requests: broker.pendingRequests(), sessionGrants: grants, defaultMode: defaultMode
    ).validated()
  }

  public func revoke(_ grant: GatewaySessionGrant) async throws -> GatewayApprovalInbox {
    _ = try grant.validated()
    try Task.checkCancellation()
    guard grant.sessionID == center.sessionID.rawValue else {
      throw GatewayFailure(
        code: .staleSession, message: "This approval belongs to an earlier Hex Agent session.")
    }
    // Revocation only narrows authority. Already-authorized operations are not rewound or repeated.
    await center.revokeSessionGrant(
      AuthorizationGrantKey(
        capability: grant.capability, operation: grant.operation, resource: grant.resource))
    return try await inbox()
  }

  public func folderAccessStatus() throws -> GatewayFolderAccessStatus {
    try folderProbe.check()
  }
}
