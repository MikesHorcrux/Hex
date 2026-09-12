import Foundation
import HexIPC

/// Default management route before a resident gateway session is connected. It never mutates local
/// UI state as if a remote schedule operation succeeded.
struct HexUnavailableHeartbeatService: HexHeartbeatManaging {
  func listHeartbeatSchedules() async throws -> GatewayHeartbeatScheduleList {
    throw HexUnavailableHeartbeatServiceError.unavailable
  }

  func listHeartbeatRuns(_ request: GatewayHeartbeatRunListRequest) async throws
    -> GatewayHeartbeatRunPage
  {
    throw HexUnavailableHeartbeatServiceError.unavailable
  }

  func addHeartbeatSchedule(
    _ request: GatewayHeartbeatScheduleRequest
  ) async throws -> GatewayHeartbeatScheduleList {
    throw HexUnavailableHeartbeatServiceError.unavailable
  }

  func removeHeartbeatSchedule(
    _ mutation: GatewayHeartbeatScheduleMutation
  ) async throws -> GatewayHeartbeatScheduleList {
    throw HexUnavailableHeartbeatServiceError.unavailable
  }

  func pauseHeartbeatSchedule(
    _ mutation: GatewayHeartbeatScheduleMutation
  ) async throws -> GatewayHeartbeatScheduleList {
    throw HexUnavailableHeartbeatServiceError.unavailable
  }

  func resumeHeartbeatSchedule(
    _ mutation: GatewayHeartbeatScheduleMutation
  ) async throws -> GatewayHeartbeatScheduleList {
    throw HexUnavailableHeartbeatServiceError.unavailable
  }
}
