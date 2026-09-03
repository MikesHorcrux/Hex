import HexMCP

nonisolated protocol HexManagedToolInstalling: Sendable {
  func install(_ tool: MCPManagedTool) async throws
  func screenControlPermissionStatus() async throws -> Bool
  func requestScreenControlPermission() async throws -> Bool
}
