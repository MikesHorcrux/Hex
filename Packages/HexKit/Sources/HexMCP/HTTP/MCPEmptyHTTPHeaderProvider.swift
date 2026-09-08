public struct MCPEmptyHTTPHeaderProvider: MCPHTTPHeaderProvider, Sendable {
  public init() {}

  public func headers(for serverID: String) async throws -> [String: String] {
    _ = serverID
    return [:]
  }
}
