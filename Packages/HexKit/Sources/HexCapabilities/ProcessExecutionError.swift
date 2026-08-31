public enum ProcessExecutionError: Error, Equatable, Sendable {
  case invalidConfiguration
  case invalidRequest
  case spawnFailed
  case ioFailure
}
