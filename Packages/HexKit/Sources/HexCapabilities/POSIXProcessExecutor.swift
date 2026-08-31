import Dispatch

public struct POSIXProcessExecutor: ProcessExecuting, Sendable {
  let configuration: ProcessExecutionConfiguration

  public init(configuration: ProcessExecutionConfiguration = .standard) {
    self.configuration = configuration
  }

  public func execute(
    _ request: ProcessExecutionRequest
  ) async throws -> ProcessExecutionResult {
    try Task.checkCancellation()
    let validated = try ProcessExecutionRequestValidator.validate(
      request,
      configuration: configuration
    )
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let process = try spawn(validated)
    return try await monitor(
      process,
      timeoutSeconds: validated.timeoutSeconds,
      startedAt: startedAt
    )
  }
}
