public struct ToolDefinition: Codable, Equatable, Sendable {
  public let name: String
  public let description: String
  public let inputSchema: [String: JSONValue]

  public init(
    name: String,
    description: String,
    inputSchema: [String: JSONValue]
  ) {
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
  }
}
