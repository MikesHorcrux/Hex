import HexIPC

extension HexGatewayClientAdapter {
  func listHeartbeatRuns(_ request: GatewayHeartbeatRunListRequest) async throws
    -> GatewayHeartbeatRunPage
  {
    try await client.listHeartbeatRuns(request)
  }

  func listHeartbeatSchedules() async throws -> GatewayHeartbeatScheduleList {
    try await client.listHeartbeats()
  }

  func addHeartbeatSchedule(
    _ request: GatewayHeartbeatScheduleRequest
  ) async throws -> GatewayHeartbeatScheduleList {
    try await client.addHeartbeat(request)
  }

  func removeHeartbeatSchedule(
    _ mutation: GatewayHeartbeatScheduleMutation
  ) async throws -> GatewayHeartbeatScheduleList {
    try await client.removeHeartbeat(mutation)
  }

  func pauseHeartbeatSchedule(
    _ mutation: GatewayHeartbeatScheduleMutation
  ) async throws -> GatewayHeartbeatScheduleList {
    try await client.pauseHeartbeat(mutation)
  }

  func resumeHeartbeatSchedule(
    _ mutation: GatewayHeartbeatScheduleMutation
  ) async throws -> GatewayHeartbeatScheduleList {
    try await client.resumeHeartbeat(mutation)
  }
}
