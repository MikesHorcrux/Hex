/// The bounded outcome vocabulary exposed by resident heartbeat management.
public enum GatewayHeartbeatOutcomeKind: String, Codable, Equatable, Sendable {
  case succeeded
  case failed
  case cancelled
  case skipped
  case interrupted
}
