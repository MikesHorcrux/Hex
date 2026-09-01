import HexCore

public enum GatewayStartRunDisposition: Codable, Equatable, Sendable {
  case started(invocationID: GatewayRunInvocationID)
  case alreadyRunning(invocationID: GatewayRunInvocationID)
  case alreadyTerminal(invocationID: GatewayRunInvocationID)
  case busy(activeRunID: AgentRunID)

  /// The admitted invocation identity. Busy responses intentionally never reveal another run's
  /// server-issued identity.
  public var invocationID: GatewayRunInvocationID? {
    switch self {
    case .started(let invocationID),
      .alreadyRunning(let invocationID),
      .alreadyTerminal(let invocationID):
      invocationID
    case .busy:
      nil
    }
  }
}
