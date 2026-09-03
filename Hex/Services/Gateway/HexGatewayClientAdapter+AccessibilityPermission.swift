import HexIPC

extension HexGatewayClientAdapter {
  func accessibilityPermissionStatus() async throws -> GatewayAccessibilityPermissionStatus {
    try await client.accessibilityPermissionStatus()
  }

  func requestAccessibilityPermission() async throws -> GatewayAccessibilityPermissionStatus {
    try await client.requestAccessibilityPermission()
  }
}
