public enum HexHeartbeatExecutionResult: Equatable, Sendable {
  case succeeded
  case failed(HexHeartbeatFailure)
}
