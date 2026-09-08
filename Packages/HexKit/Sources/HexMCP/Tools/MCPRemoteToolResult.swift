import HexCore

public struct MCPRemoteToolResult: Equatable, Sendable {
  public let content: [MCPToolContent]
  public let structuredContent: JSONValue?
  /// Bounded server-provided result metadata; data, never host authorization or instructions.
  public let metadata: JSONValue?
  public let isError: Bool

  public init(
    content: [MCPToolContent],
    structuredContent: JSONValue? = nil,
    metadata: JSONValue? = nil,
    isError: Bool
  ) {
    self.content = content
    self.structuredContent = structuredContent
    self.metadata = metadata
    self.isError = isError
  }
}
