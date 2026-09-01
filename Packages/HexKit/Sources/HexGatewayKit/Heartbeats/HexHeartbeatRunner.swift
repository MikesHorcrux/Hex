public protocol HexHeartbeatRunner: Sendable {
  /// The runner is the only boundary that may invoke inference. The scheduler never calls it while
  /// waiting for a future due date, while globally paused, or for an idle schedule.
  func run(_ request: HexHeartbeatExecutionRequest) async throws -> HexHeartbeatExecutionResult
}
