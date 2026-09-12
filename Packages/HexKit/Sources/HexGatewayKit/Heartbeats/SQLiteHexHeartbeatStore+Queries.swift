import Foundation

extension SQLiteHexHeartbeatStore {
  static let receiptColumns =
    "SELECT sequence,schedule_id,due_at,lease_id,run_id,expires_at,is_terminal,payload FROM heartbeat_receipts"

  public func receipts(
    scheduleID: HexHeartbeatScheduleID? = nil, after: HexHeartbeatReceiptCursor? = nil,
    limit: Int = 20
  ) async throws -> HexHeartbeatReceiptPage {
    guard (1...100).contains(limit) else { throw SQLiteHexHeartbeatStoreError.invalidCursor }
    return try transaction {
      let storeID = try storeIdentity()
      let highWater: Int64
      let before: Int64
      if let after {
        guard after.storeID == storeID, after.scheduleID == scheduleID, after.highWaterSequence > 0,
          after.beforeSequence > 0, after.beforeSequence <= after.highWaterSequence
        else {
          throw SQLiteHexHeartbeatStoreError.invalidCursor
        }
        highWater = after.highWaterSequence
        before = after.beforeSequence
      } else {
        let maximum = try database.rows("SELECT COALESCE(MAX(sequence),0) FROM heartbeat_receipts")
        guard let row = maximum.first, case .integer(let value) = row.first, value >= 0,
          value < Int64.max
        else {
          throw SQLiteHexHeartbeatStoreError.corrupt
        }
        highWater = value
        before = value + 1
      }
      var bindings: [SQLiteHeartbeatConnectionValue] = [.integer(highWater), .integer(before)]
      var query = Self.receiptColumns + " WHERE sequence<=? AND sequence<?"
      if let scheduleID {
        query += " AND schedule_id=?"
        bindings.append(.text(scheduleID.description))
      }
      query += " ORDER BY sequence DESC LIMIT ?"
      bindings.append(.integer(Int64(limit + 1)))
      let rows = try database.rows(query, bindings, maximumRows: limit + 1)
      var receipts: [HexHeartbeatOccurrenceReceipt] = []
      var lastSequence: Int64?
      var bytes = 1_024
      for row in rows.prefix(limit) {
        let (sequence, receipt) = try decodeReceiptRow(row)
        let size = try encode(receipt, maximumBytes: 32_768).count
        if bytes + size > 512 * 1_024 { break }
        bytes += size
        receipts.append(receipt)
        lastSequence = sequence
      }
      let next =
        rows.count > receipts.count
        ? lastSequence.map {
          HexHeartbeatReceiptCursor(
            storeID: storeID, scheduleID: scheduleID,
            highWaterSequence: highWater, beforeSequence: $0)
        } : nil
      return HexHeartbeatReceiptPage(storeID: storeID, receipts: receipts, nextCursor: next)
    }
  }

  public func expiredReceipts(at now: Date, limit: Int = 100) async throws
    -> [HexHeartbeatOccurrenceReceipt]
  {
    try validate(now)
    guard (1...100).contains(limit) else { throw SQLiteHexHeartbeatStoreError.invalidCursor }
    return try transaction {
      let rows = try database.rows(
        Self.receiptColumns
          + " WHERE is_terminal=0 AND expires_at<=? ORDER BY expires_at,sequence LIMIT ?",
        [.real(now.timeIntervalSinceReferenceDate), .integer(Int64(limit))], maximumRows: limit)
      return try rows.map { try decodeReceiptRow($0).1 }
    }
  }

  public func nextPendingReceiptExpiry() async throws -> Date? {
    try transaction {
      let rows = try database.rows(
        "SELECT MIN(expires_at) FROM heartbeat_receipts WHERE is_terminal=0")
      guard let row = rows.first else { throw SQLiteHexHeartbeatStoreError.corrupt }
      switch row.first {
      case .null: return nil
      case .real(let value):
        let date = Date(timeIntervalSinceReferenceDate: value)
        try validate(date)
        return date
      default: throw SQLiteHexHeartbeatStoreError.corrupt
      }
    }
  }

  func decodeReceiptRow(_ row: [SQLiteHeartbeatConnectionValue]) throws -> (
    Int64, HexHeartbeatOccurrenceReceipt
  ) {
    guard row.count == 8, case .integer(let sequence) = row[0], sequence > 0,
      case .text(let scheduleID) = row[1], case .real(let dueAt) = row[2],
      case .integer(let terminal) = row[6], case .blob(let data) = row[7]
    else {
      throw SQLiteHexHeartbeatStoreError.corrupt
    }
    let receipt = try validate(decode(HexHeartbeatOccurrenceReceipt.self, data))
    guard scheduleID == receipt.occurrence.scheduleID.description,
      dueAt == receipt.occurrence.dueAt.timeIntervalSinceReferenceDate,
      terminal == (receipt.outcome == nil ? 0 : 1),
      try optionalText(row[3]) == receipt.lease?.leaseID.uuidString,
      try optionalText(row[4]) == receipt.runID?.rawValue.uuidString,
      try optionalReal(row[5]) == receipt.lease?.expiresAt.timeIntervalSinceReferenceDate
    else {
      throw SQLiteHexHeartbeatStoreError.corrupt
    }
    return (sequence, receipt)
  }

  private func optionalText(_ value: SQLiteHeartbeatConnectionValue) throws -> String? {
    switch value {
    case .null: nil
    case .text(let text): text
    default: throw SQLiteHexHeartbeatStoreError.corrupt
    }
  }

  private func optionalReal(_ value: SQLiteHeartbeatConnectionValue) throws -> Double? {
    switch value {
    case .null: nil
    case .real(let number): number
    default: throw SQLiteHexHeartbeatStoreError.corrupt
    }
  }
}
