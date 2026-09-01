import Foundation

public struct HexHeartbeatExecutionRequest: Codable, Equatable, Sendable {
  public let schedule: HexHeartbeatSchedule
  public let occurrence: HexHeartbeatOccurrenceID
  public let lease: HexHeartbeatLease

  public init(
    schedule: HexHeartbeatSchedule,
    occurrence: HexHeartbeatOccurrenceID,
    lease: HexHeartbeatLease
  ) {
    self.schedule = schedule
    self.occurrence = occurrence
    self.lease = lease
  }
}
