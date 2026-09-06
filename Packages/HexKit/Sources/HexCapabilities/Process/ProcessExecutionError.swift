public enum ProcessExecutionError: Error, Equatable, Sendable {
  case invalidConfiguration
  case invalidRequest
  case authorizationDetailsTooLarge
  case authorizationRequired
  case authorizationStateUnavailable
  case spawnFailed
  case ioFailure
  case cleanupFailed
  case outputCaptureUnavailable
}
