public struct GatewayToolServerRequest: Codable, Equatable, Sendable {
  public let serverID: String

  public init(serverID: String) { self.serverID = serverID }

  public func validated() throws -> Self {
    guard (1...32).contains(serverID.utf8.count),
      serverID.utf8.allSatisfy({
        (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
      })
    else {
      throw GatewayFailure(code: .malformedPayload, message: "The tool server identity is invalid.")
    }
    return self
  }
}
