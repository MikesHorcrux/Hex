import Foundation
import Testing

@testable import HexMCP

@Suite("Managed MCP external integration")
struct ManagedMCPExternalIntegrationTests {
  @Test("Pinned Playwright and Peekaboo servers negotiate and list tools")
  func listsInstalledManagedToolsWhenExplicitlyEnabled() async throws {
    guard
      ProcessInfo.processInfo.environment["HEX_RUN_MANAGED_MCP_INTEGRATION"] == "1",
      let rootPath = ProcessInfo.processInfo.environment["HEX_MANAGED_TOOLS_ROOT"]
    else {
      return
    }
    let layout = try MCPManagedToolLayout(
      rootURL: URL(fileURLWithPath: rootPath, isDirectory: true)
    )
    let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let configurations = [
      try MCPServerConfiguration.playwright(layout: layout, workspaceRoot: workspace),
      try MCPServerConfiguration.peekaboo(layout: layout, workspaceRoot: workspace),
    ]

    for configuration in configurations {
      let session = LocalMCPClientSession(configuration: configuration)
      do {
        try await session.connect()
        let tools = try await session.listTools()
        #expect(!tools.isEmpty)
        switch configuration.serverID {
        case "playwright":
          #expect(tools.contains { $0.name == "browser_navigate" })
        case "peekaboo":
          #expect(tools.contains { $0.name == "see" || $0.name == "image" })
        default:
          Issue.record("Unexpected managed MCP server identifier.")
        }
      } catch {
        await session.disconnect()
        throw error
      }
      await session.disconnect()
    }
  }
}
