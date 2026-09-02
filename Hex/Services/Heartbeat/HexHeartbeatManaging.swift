import HexIPC

/// App-side capability for managing durable resident heartbeat schedules. Implementations must use
/// the same authenticated gateway session as interactive agent runs.
nonisolated protocol HexHeartbeatManaging: Sendable {
  func listHeartbeatSchedules() async throws -> GatewayHeartbeatScheduleList

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
