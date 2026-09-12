import HexMCP

nonisolated protocol HexManagedToolInstalling: Sendable {
  func install(_ tool: MCPManagedTool) async throws
}
