import HexIPC

/// App-side capability for managing durable resident heartbeat schedules. Implementations must use
/// the same authenticated gateway session as interactive agent runs.
nonisolated protocol HexHeartbeatManaging: Sendable {
  func listHeartbeatSchedules() async throws -> GatewayHeartbeatScheduleList
  func listHeartbeatRuns(_ request: GatewayHeartbeatRunListRequest) async throws
    -> GatewayHeartbeatRunPage

  func addHeartbeatSchedule(
    _ request: GatewayHeartbeatScheduleRequest
  ) async throws -> GatewayHeartbeatScheduleList

  func removeHeartbeatSchedule(
    _ mutation: GatewayHeartbeatScheduleMutation
  ) async throws -> GatewayHeartbeatScheduleList

  func pauseHeartbeatSchedule(
    _ mutation: GatewayHeartbeatScheduleMutation
  ) async throws -> GatewayHeartbeatScheduleList

  func resumeHeartbeatSchedule(
    _ mutation: GatewayHeartbeatScheduleMutation
  ) async throws -> GatewayHeartbeatScheduleList
}

extension HexHeartbeatManaging {
  func listHeartbeatRuns(_ request: GatewayHeartbeatRunListRequest) async throws
    -> GatewayHeartbeatRunPage
  {
    throw GatewayFailure(
      code: .transportUnavailable,
      message: "The connected resident does not expose scheduled run history.")
  }
}
