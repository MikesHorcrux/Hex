public enum MCPToolContent: Equatable, Sendable {
  case text(String)
  case image(data: String, mimeType: String)
  case audio(data: String, mimeType: String)
  case resourceLink(MCPResourceLink)
  case resource(MCPEmbeddedResource)
}
