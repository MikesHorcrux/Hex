public enum MessageContent: Codable, Equatable, Sendable {
  case text(String)
  case image(ImageContent)
  case toolCall(ToolCall)
  case toolResult(ToolResult)
}
