/// A non-secret MCP transport that the resident gateway knows how to construct.
public enum HexResidentMCPTransport: String, Codable, Equatable, Sendable {
  case peekaboo
  case playwright
  case xcode
  case streamableHTTP
  case stdio
}
