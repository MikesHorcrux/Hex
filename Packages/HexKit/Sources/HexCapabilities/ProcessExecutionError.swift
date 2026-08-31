public enum ProcessExecutionError: Error, Equatable, Sendable {
  case invalidConfiguration
  case invalidRequest
  case authorizationRequired
  case authorizationStateUnavailable
  case spawnFailed
  case ioFailure
  case cleanupFailed
}
