import Foundation

/// The bounded response shared by heartbeat list and mutation operations.
public struct GatewayHeartbeatScheduleList: Codable, Equatable, Sendable {
  public let schedules: [GatewayHeartbeatSchedule]
  public let isPaused: Bool

  public init(schedules: [GatewayHeartbeatSchedule] = [], isPaused: Bool = false) {
    self.schedules = schedules
    self.isPaused = isPaused
  }

  public func validated() throws -> Self {
    guard schedules.count <= Self.maximumSchedules else {
      throw GatewayFailure(
        code: .capacityExceeded,
        message: "The resident gateway returned more heartbeat schedules than the bounded limit."
      )
    }
    var identifiers = Set<UUID>()
    for schedule in schedules {
      _ = try schedule.validated()
      guard identifiers.insert(schedule.id).inserted else {
        throw GatewayFailure(
          code: .malformedPayload,
          message: "The resident gateway returned duplicate heartbeat schedule identities."
        )
      }
    }
    return self
  }

  public static let maximumSchedules = 64
}
