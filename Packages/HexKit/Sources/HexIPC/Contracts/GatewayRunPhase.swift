public enum GatewayRunPhase: String, Codable, Equatable, Sendable {
  case starting
  case running
  case cancelling
  case terminal
}
