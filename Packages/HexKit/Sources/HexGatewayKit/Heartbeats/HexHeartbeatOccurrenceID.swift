import Foundation

public struct HexHeartbeatOccurrenceID: Codable, Equatable, Hashable, Sendable {
  public let scheduleID: HexHeartbeatScheduleID
  public let dueAt: Date

  public init(scheduleID: HexHeartbeatScheduleID, dueAt: Date) {
    self.scheduleID = scheduleID
    self.dueAt = dueAt
  }
}
