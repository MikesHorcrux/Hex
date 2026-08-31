import HexCore

public enum GatewayStartRunDisposition: Codable, Equatable, Sendable {
  case started
  case alreadyRunning
  case alreadyTerminal
  case busy(activeRunID: AgentRunID)
}
