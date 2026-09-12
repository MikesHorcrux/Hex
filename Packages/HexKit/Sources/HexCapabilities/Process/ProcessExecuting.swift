public protocol ProcessExecuting: Sendable {
  /// A cancelled, already-started process may return a `.cancelled` receipt after cleanup is
  /// confirmed, preserving partial output for journaling. Cancellation before spawn still throws;
  /// callers must inspect termination rather than treating every returned value as success.
  func execute(_ request: ProcessExecutionRequest) async throws -> ProcessExecutionResult
}
