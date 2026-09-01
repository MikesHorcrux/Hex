public enum HexHeartbeatFailureCode: String, Codable, Equatable, Sendable {
  case runnerFailed
  case leaseExpired
  case storeFailed
  case invalidSchedule
  case cancelled
}
