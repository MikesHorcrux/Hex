import HexIPC

/// App-facing boundary for Accessibility checks performed by the resident gateway process.
nonisolated protocol HexAccessibilityPermissionServicing: Sendable {
  func accessibilityPermissionStatus() async throws -> GatewayAccessibilityPermissionStatus
  func requestAccessibilityPermission() async throws -> GatewayAccessibilityPermissionStatus
}
