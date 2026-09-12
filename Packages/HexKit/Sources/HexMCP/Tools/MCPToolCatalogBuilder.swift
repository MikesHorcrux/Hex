import Foundation
import HexCore

enum MCPToolCatalogBuilder {
  static func build(
    sessions: [any MCPClientSession]
  ) async throws -> MCPToolCatalog {
    var definitions: [ToolDefinition] = []
    var routes: [String: MCPToolRoute] = [:]

    for session in sessions.sorted(by: { $0.serverID < $1.serverID }) {
      let tools = try await session.listTools()
      guard tools.count <= 4_096, definitions.count <= 4_096 - tools.count else {
        throw MCPToolExecutorError.invalidToolDefinition
      }
      var remoteNames = Set<String>()
      for tool in tools {
        guard remoteNames.insert(tool.name).inserted else {
          throw MCPToolExecutorError.duplicateTool
        }
        guard !tool.requiresTaskExecution else { continue }
        let exposedName = MCPExposedToolName.make(
          serverID: session.serverID,
          remoteName: tool.name
        )
        let description = tool.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDescription =
          description?.isEmpty == false
          ? description ?? ""
          : "MCP tool \(tool.name) from \(session.serverID)."
        guard
          isValidToolName(tool.name),
          isValidToolName(exposedName),
          resolvedDescription.utf8.count <= 4_096,
          !resolvedDescription.contains("\0"),
          tool.inputSchema["type"] == .string("object"),
          MCPJSONValueValidator.isValid(
            .object(tool.inputSchema),
            maximumNodes: 10_000,
            maximumStringBytes: 32 * 1_024,
            maximumEstimatedBytes: 64 * 1_024
          ),
          let schemaData = try? JSONEncoder().encode(tool.inputSchema),
          schemaData.count <= 64 * 1_024
        else {
          throw MCPToolExecutorError.invalidToolDefinition
        }
        guard routes[exposedName] == nil else {
          throw MCPToolExecutorError.duplicateTool
        }
        definitions.append(
          ToolDefinition(
            name: exposedName,
            description: resolvedDescription,
            inputSchema: tool.inputSchema
          )
        )
        routes[exposedName] = MCPToolRoute(
          session: session,
          serverID: session.serverID,
          remoteName: tool.name
        )
      }
    }

    return MCPToolCatalog(
      definitions: definitions.sorted { $0.name < $1.name },
      routes: routes
    )
  }

  static func isValidServerID(_ value: String) -> Bool {
    !value.isEmpty
      && value.utf8.count <= 32
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte)
          || (97...122).contains(byte)
          || byte == 45
          || byte == 95
      }
  }

  static func isValidToolName(_ value: String) -> Bool {
    !value.isEmpty
      && value.utf8.count <= 128
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte)
          || (65...90).contains(byte)
          || (97...122).contains(byte)
          || byte == 45
          || byte == 46
          || byte == 95
      }
  }
}
