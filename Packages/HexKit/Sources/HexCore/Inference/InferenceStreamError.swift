public enum InferenceStreamError: Error, Equatable, Sendable {
  case alreadyConsumed
  case cancelled
  case closed
  case concurrentRead
}
