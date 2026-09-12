import Foundation

/// Descending keyset pagination bound to one store identity and first-page high-water mark.
public struct HexHeartbeatReceiptCursor: Codable, Equatable, Sendable {
  public let storeID: UUID
  public let scheduleID: HexHeartbeatScheduleID?
  public let highWaterSequence: Int64
  public let beforeSequence: Int64

  public init(
    storeID: UUID, scheduleID: HexHeartbeatScheduleID?, highWaterSequence: Int64,
    beforeSequence: Int64
  ) {
    self.storeID = storeID
    self.scheduleID = scheduleID
    self.highWaterSequence = highWaterSequence
    self.beforeSequence = beforeSequence
  }
}
