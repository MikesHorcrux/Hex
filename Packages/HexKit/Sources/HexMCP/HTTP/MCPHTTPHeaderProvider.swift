public protocol MCPHTTPHeaderProvider: Sendable {
  /// Returns process-only headers for one request. Implementations should retrieve secrets from a
  /// secret store rather than persisting them in MCP server configuration.
  func headers(for serverID: String) async throws -> [String: String]
}
