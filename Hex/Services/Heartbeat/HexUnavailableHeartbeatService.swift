import Foundation
import HexIPC

/// Default management route before a resident gateway session is connected. It never mutates local
/// UI state as if a remote schedule operation succeeded.
struct HexUnavailableHeartbeatService: HexHeartbeatManaging {
  enum ServiceError: Error, Equatable, LocalizedError, Sendable {
    case unavailable

    var errorDescription: String? {
      "Heartbeat schedules are unavailable until the resident gateway is connected."
    }
  }

  func listHeartbeatSchedules() async throws -> GatewayHeartbeatScheduleList {
    throw ServiceError.unavailable
  }

  func addHeartbeatSchedule(
    _ request: GatewayHeartbeatScheduleRequest
  ) async throws -> GatewayHeartbeatScheduleList {
    throw ServiceError.unavailable
  }

  func removeHeartbeatSchedule(
    _ mutation: GatewayHeartbeatScheduleMutation
  ) async throws -> GatewayHeartbeatScheduleList {
    throw ServiceError.unavailable
  }

  func pauseHeartbeatSchedule(
    _ mutation: GatewayHeartbeatScheduleMutation
  ) async throws -> GatewayHeartbeatScheduleList {
    throw ServiceError.unavailable
  }

  func resumeHeartbeatSchedule(
    _ mutation: GatewayHeartbeatScheduleMutation
  ) async throws -> GatewayHeartbeatScheduleList {
    throw ServiceError.unavailable
  }
}
