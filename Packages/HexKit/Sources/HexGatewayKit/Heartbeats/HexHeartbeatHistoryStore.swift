import Foundation

/// Retains occurrence identities independently of schedules. Querying or reconciling never runs work.
public protocol HexHeartbeatHistoryStore: HexHeartbeatStore {
  func receipts(scheduleID: HexHeartbeatScheduleID?, after: HexHeartbeatReceiptCursor?, limit: Int)
    async throws -> HexHeartbeatReceiptPage
  func expiredReceipts(at now: Date, limit: Int) async throws -> [HexHeartbeatOccurrenceReceipt]
  func nextPendingReceiptExpiry() async throws -> Date?
  /// Host-only recovery decision after inspecting the exact run's live and durable state. Unlike
  /// ordinary completion, expiry is allowed; a different retained lease or outcome is never allowed.
  func reconcile(_ completion: HexHeartbeatCompletion, at now: Date)
    async throws -> HexHeartbeatCompletionDisposition
}

extension HexHeartbeatHistoryStore {
  public func receipts(limit: Int = 20) async throws -> HexHeartbeatReceiptPage {
    try await receipts(scheduleID: nil, after: nil, limit: limit)
  }

  public func expiredReceipts(at now: Date) async throws
    -> [HexHeartbeatOccurrenceReceipt]
  {
    try await expiredReceipts(at: now, limit: 100)
  }
}
