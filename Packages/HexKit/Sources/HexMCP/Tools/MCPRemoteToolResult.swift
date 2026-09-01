import HexCore

public struct MCPRemoteToolResult: Equatable, Sendable {
  public let content: [MCPToolContent]
  public let structuredContent: JSONValue?
  public let isError: Bool

  public init(
    content: [MCPToolContent],
    structuredContent: JSONValue? = nil,
    isError: Bool
  ) {
    self.content = content
    self.structuredContent = structuredContent
    self.isError = isError
  }
}
