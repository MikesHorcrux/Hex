public struct ToolCall: Identifiable, Codable, Equatable, Sendable {
  public let id: ToolCallID
  public let name: String
  public let arguments: [String: JSONValue]

  public init(
    id: ToolCallID = ToolCallID(),
    name: String,
    arguments: [String: JSONValue]
  ) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
}
