public enum GatewayToolServerState: String, Codable, Equatable, Sendable {
  case disconnected
  case connecting
  case ready
  case unavailable
}
