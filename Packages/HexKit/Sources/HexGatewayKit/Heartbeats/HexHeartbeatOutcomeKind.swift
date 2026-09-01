public enum HexHeartbeatOutcomeKind: String, Codable, Equatable, Sendable {
  case succeeded
  case failed
  case cancelled
  case skipped
  case interrupted
}
