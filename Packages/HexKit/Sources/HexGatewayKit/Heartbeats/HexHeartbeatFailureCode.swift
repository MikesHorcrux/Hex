public enum HexHeartbeatFailureCode: String, Codable, Equatable, Sendable {
  case runnerFailed
  case gatewayBusy
  case authorizationRequired
  case timedOut
  case leaseExpired
  case storeFailed
  case invalidSchedule
  case cancelled
}
