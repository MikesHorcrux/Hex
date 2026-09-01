public protocol ProcessExecuting: Sendable {
  func execute(_ request: ProcessExecutionRequest) async throws -> ProcessExecutionResult
}
