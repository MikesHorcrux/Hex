import HexIPC

/// Fail-closed permission service used when this app composition has no resident gateway route.
struct HexUnavailableAccessibilityPermissionService: HexAccessibilityPermissionServicing {
  func accessibilityPermissionStatus() async throws -> GatewayAccessibilityPermissionStatus {
    throw unavailableFailure
  }

  func requestAccessibilityPermission() async throws -> GatewayAccessibilityPermissionStatus {
    throw unavailableFailure
  }

  private var unavailableFailure: GatewayFailure {
    GatewayFailure(
      code: .transportUnavailable,
      message: "Accessibility must be checked by the resident Hex Agent."
    )
  }
}
