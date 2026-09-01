import HexCore

public struct MCPRemoteToolCall: Equatable, Sendable {
  public let name: String
  public let arguments: [String: JSONValue]

  public init(
    name: String,
    arguments: [String: JSONValue]
  ) {
    self.name = name
    self.arguments = arguments
  }
}
