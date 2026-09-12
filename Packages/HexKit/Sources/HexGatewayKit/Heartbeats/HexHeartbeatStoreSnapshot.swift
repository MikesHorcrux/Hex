import Foundation

public struct HexHeartbeatStoreSnapshot: Codable, Equatable, Sendable {
  public var schedules: [HexHeartbeatSchedule]
  public let isPaused: Bool

  public init(schedules: [HexHeartbeatSchedule] = [], isPaused: Bool = false) {
    self.schedules = schedules
    self.isPaused = isPaused
  }
}
