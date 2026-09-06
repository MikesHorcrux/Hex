public struct GatewayToolServerStatus: Codable, Equatable, Sendable {
  public let serverID: String
  public let state: GatewayToolServerState
  public let failure: GatewayToolServerFailure?
  public let availableToolCount: Int?

  public init(
    serverID: String, state: GatewayToolServerState, failure: GatewayToolServerFailure? = nil,
    availableToolCount: Int? = nil
  ) {
    self.serverID = serverID
    self.state = state
    self.failure = failure
    self.availableToolCount = availableToolCount
  }

  public func validated() throws -> Self {
    _ = try GatewayToolServerRequest(serverID: serverID).validated()
    guard failure == nil || state == .unavailable else { throw invalidStatus() }
    if state == .ready {
      guard let availableToolCount, (0...4096).contains(availableToolCount), failure == nil else {
        throw invalidStatus()
      }
    } else if availableToolCount != nil {
      throw invalidStatus()
    }
    return self
  }

  public func validated(for request: GatewayToolServerRequest) throws -> Self {
    _ = try request.validated()
    _ = try validated()
    guard serverID == request.serverID else {
      throw GatewayFailure(
        code: .malformedPayload, message: "The tool server response belongs to another server.")
    }
    return self
  }

  private func invalidStatus() -> GatewayFailure {
    GatewayFailure(code: .malformedPayload, message: "The tool server status is inconsistent.")
  }
}
