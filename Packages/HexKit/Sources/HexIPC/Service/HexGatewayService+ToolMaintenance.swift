import Foundation

extension HexGatewayService {
  /// Trusted host maintenance owns an idle gateway until the underlying operation actually
  /// returns. Shutdown cancels and drains it; caller cancellation cannot release resources early.
  public func withIdleToolMaintenance<Result: Sendable>(
    sessionID: GatewaySessionID? = nil,
    operation: @escaping @Sendable () async throws -> Result
  ) async throws -> Result {
    try Task.checkCancellation()
    if let sessionID { try requireSession(sessionID) }
    try requireAcceptingAdmissions()
    guard activeRunID == nil, liveDriverTasks.isEmpty, toolMaintenance == nil else {
      throw toolMaintenanceFailure()
    }
    let id = UUID()
    let task = Task { try await operation() }
    toolMaintenance = (id, { task.cancel() })
    defer {
      if toolMaintenance?.id == id {
        toolMaintenance = nil
        resumeDrainWaitersIfIdle()
      }
    }
    return try await withTaskCancellationHandler {
      let result = try await task.value
      try Task.checkCancellation()
      return result
    } onCancel: {
      task.cancel()
    }
  }

  func toolMaintenanceFailure() -> GatewayFailure {
    GatewayFailure(
      code: .toolMaintenanceInProgress,
      message:
        "Tool maintenance requires an idle agent. No new run or reconnect was started; wait for current work to finish, then retry.",
      isRetryable: true)
  }
}
