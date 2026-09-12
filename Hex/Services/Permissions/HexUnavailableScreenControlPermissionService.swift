import HexIPC

/// Fail-closed screen-control service used when this app composition has no resident gateway.
struct HexUnavailableScreenControlPermissionService: HexScreenControlPermissionServicing {
  func screenControlPermissionStatus() async throws -> GatewayScreenControlPermissionStatus {
    throw unavailableFailure
  }

  func requestScreenControlPermission() async throws -> GatewayScreenControlPermissionStatus {
    throw unavailableFailure
  }

  private var unavailableFailure: GatewayFailure {
    GatewayFailure(
      code: .transportUnavailable,
      message: "Screen control must be checked by the resident Hex Agent."
    )
  }
}
