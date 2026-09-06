public enum ProcessTermination: Equatable, Sendable {
  case exited(code: Int32)
  case signaled(signal: Int32)
  case timedOut
  /// Cancellation after spawn, with the owned process group terminated and leader reaped.
  /// This is a known receipt; cancellation before spawn and uncertain cleanup still throw.
  case cancelled
  case outputLimitExceeded
  /// The process group was terminated because its output could no longer be captured safely.
  case outputCaptureFailed
}
