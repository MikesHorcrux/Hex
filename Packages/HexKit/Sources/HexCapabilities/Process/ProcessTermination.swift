public enum ProcessTermination: Equatable, Sendable {
  case exited(code: Int32)
  case signaled(signal: Int32)
  case timedOut
  case outputLimitExceeded
}
