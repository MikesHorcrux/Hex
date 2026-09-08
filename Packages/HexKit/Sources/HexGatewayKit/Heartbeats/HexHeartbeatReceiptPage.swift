import Foundation

public struct HexHeartbeatReceiptPage: Codable, Equatable, Sendable {
  public let storeID: UUID
  public let receipts: [HexHeartbeatOccurrenceReceipt]
  public let nextCursor: HexHeartbeatReceiptCursor?

  public init(
    storeID: UUID, receipts: [HexHeartbeatOccurrenceReceipt],
    nextCursor: HexHeartbeatReceiptCursor?
  ) {
    self.storeID = storeID
    self.receipts = receipts
    self.nextCursor = nextCursor
  }
}
