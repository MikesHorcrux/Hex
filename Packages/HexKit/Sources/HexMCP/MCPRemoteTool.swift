import HexCore

public struct MCPRemoteTool: Equatable, Sendable {
  public let name: String
  public let description: String?
  public let inputSchema: [String: JSONValue]

  public init(
    name: String,
    description: String? = nil,
    inputSchema: [String: JSONValue]
  ) {
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
  }
}
