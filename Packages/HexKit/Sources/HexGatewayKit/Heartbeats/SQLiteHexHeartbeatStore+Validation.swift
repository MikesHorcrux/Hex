import Foundation
import HexCore

extension SQLiteHexHeartbeatStore {
  func validate(_ schedule: HexHeartbeatSchedule) throws -> HexHeartbeatSchedule {
    let validated = try schedule.validated()
    try validate(schedule.id.rawValue)
    try validate(schedule.nextDueAt)
    if let lease = schedule.activeLease { try validate(lease) }
    if let outcome = schedule.lastOutcome { try validate(outcome) }
    if let leaseID = schedule.lastCompletedLeaseID { try validate(leaseID) }
    return validated
  }

  func validate(_ lease: HexHeartbeatLease) throws {
    try validate(lease.leaseID)
    try validate(lease.occurrence.scheduleID.rawValue)
    try validate(lease.occurrence.dueAt)
    try validate(lease.claimedAt)
    try validate(lease.expiresAt)
    guard lease.expiresAt > lease.claimedAt else { throw SQLiteHexHeartbeatStoreError.corrupt }
    if let runID = lease.runID { try validate(runID.rawValue) }
  }

  func validate(_ outcome: HexHeartbeatOutcome) throws {
    try validate(outcome.occurrence.scheduleID.rawValue)
    try validate(outcome.occurrence.dueAt)
    try validate(outcome.completedAt)
    if let failure = outcome.failure {
      guard !failure.message.isEmpty, failure.message.utf8.count <= 4_096 else {
        throw SQLiteHexHeartbeatStoreError.payloadTooLarge
      }
    }
    if outcome.kind == .succeeded || outcome.kind == .skipped {
      guard outcome.failure == nil else { throw SQLiteHexHeartbeatStoreError.corrupt }
    }
  }

  @discardableResult
  func validate(_ receipt: HexHeartbeatOccurrenceReceipt) throws -> HexHeartbeatOccurrenceReceipt {
    try validate(receipt.occurrence.scheduleID.rawValue)
    try validate(receipt.occurrence.dueAt)
    guard !receipt.scheduleName.isEmpty,
      receipt.scheduleName.utf8.count <= HexHeartbeatSchedule.maximumNameBytes
    else {
      throw SQLiteHexHeartbeatStoreError.corrupt
    }
    if let lease = receipt.lease {
      try validate(lease)
      guard lease.occurrence == receipt.occurrence else {
        throw SQLiteHexHeartbeatStoreError.corrupt
      }
    } else {
      guard receipt.outcome != nil, receipt.journal == nil else {
        throw SQLiteHexHeartbeatStoreError.corrupt
      }
    }
    if let outcome = receipt.outcome {
      try validate(outcome)
      guard outcome.occurrence == receipt.occurrence else {
        throw SQLiteHexHeartbeatStoreError.corrupt
      }
    } else {
      guard receipt.lease != nil, receipt.nextDueAtAfterCompletion == nil, receipt.journal == nil
      else {
        throw SQLiteHexHeartbeatStoreError.corrupt
      }
    }
    if let next = receipt.nextDueAtAfterCompletion { try validate(next) }
    if let journal = receipt.journal {
      try validate(journal.runID.rawValue)
      try validate(journal.firstEventID.rawValue)
      guard journal.runID == receipt.runID, journal.terminalSequence >= 2,
        receipt.outcome != nil, receipt.outcome?.kind != .skipped
      else {
        throw SQLiteHexHeartbeatStoreError.corrupt
      }
    }
    return receipt
  }

  func validate(_ date: Date) throws {
    guard date.timeIntervalSinceReferenceDate.isFinite else {
      throw SQLiteHexHeartbeatStoreError.corrupt
    }
  }

  func validate(_ id: UUID) throws {
    guard id.uuidString != "00000000-0000-0000-0000-000000000000" else {
      throw SQLiteHexHeartbeatStoreError.corrupt
    }
  }

  func storeIdentity() throws -> UUID {
    let rows = try database.rows("SELECT store_id FROM heartbeat_metadata WHERE singleton=1")
    guard let row = rows.first, case .text(let text) = row.first, let id = UUID(uuidString: text)
    else {
      throw SQLiteHexHeartbeatStoreError.corrupt
    }
    try validate(id)
    return id
  }

  func validateSchemaIdentity() throws {
    let rows = try database.rows("PRAGMA user_version")
    guard let row = rows.first, case .integer(1) = row.first else {
      throw SQLiteHexHeartbeatStoreError.unsupportedSchema
    }
    _ = try storeIdentity()
    let metadata = try database.rows(
      "SELECT legacy_imported FROM heartbeat_metadata WHERE singleton=1")
    guard let row = metadata.first, case .integer(1) = row.first else {
      throw SQLiteHexHeartbeatStoreError.corrupt
    }
  }
}
