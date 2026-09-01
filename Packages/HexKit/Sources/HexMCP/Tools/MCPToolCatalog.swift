import HexCore

struct MCPToolCatalog: Sendable {
  let definitions: [ToolDefinition]
  let routes: [String: MCPToolRoute]
}
