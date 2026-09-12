import HexIPC

extension HexGatewayClientAdapter {
  func screenControlPermissionStatus() async throws -> GatewayScreenControlPermissionStatus {
    try await client.screenControlPermissionStatus()
  }

  func requestScreenControlPermission() async throws -> GatewayScreenControlPermissionStatus {
    try await client.requestScreenControlPermission()
  }
}
