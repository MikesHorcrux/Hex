import Foundation

extension SQLiteHexHeartbeatStore {
  public func claim(_ lease: HexHeartbeatLease, at now: Date) async throws
    -> HexHeartbeatClaimDisposition
  {
    try validate(now)
    try validate(lease)
    guard lease.runID != nil, lease.expiresAt > now else {
      throw HexHeartbeatStoreError.invalidLease(
        "New scheduled work requires a durable run identity and an unexpired lease.")
    }
    return try transaction {
      let snapshot = try readSnapshot()
      guard !snapshot.isPaused else { return .schedulePaused }
      guard var schedule = snapshot.schedules.first(where: { $0.id == lease.occurrence.scheduleID })
      else { return .scheduleMissing }
      if let previous = try receipt(for: lease.occurrence) {
        return previous.outcome == nil ? .alreadyClaimed : .alreadyCompleted
      }
      guard schedule.activeLease == nil else { return .scheduleBusy }
      // A removed/recreated schedule cannot bypass an older pending receipt's ownership.
      let pending = try database.rows(
        "SELECT sequence FROM heartbeat_receipts WHERE schedule_id=? AND is_terminal=0 LIMIT 1",
        [.text(schedule.id.description)])
      guard pending.isEmpty else { return .scheduleBusy }
      guard !schedule.isPaused else { return .schedulePaused }
      guard schedule.nextDueAt == lease.occurrence.dueAt, schedule.nextDueAt <= now else {
        return .scheduleNotDue
      }
      try writeReceipt(
        HexHeartbeatOccurrenceReceipt(
          occurrence: lease.occurrence, scheduleName: schedule.name, lease: lease), inserting: true)
      schedule.activeLease = lease
      try writeSchedule(schedule)
      return .claimed
    }
  }

  public func complete(_ completion: HexHeartbeatCompletion, at now: Date) async throws
    -> HexHeartbeatCompletionDisposition
  {
    try transaction { try finish(completion, at: now, permitsExpiredLease: false) }
  }

  public func reconcile(_ completion: HexHeartbeatCompletion, at now: Date) async throws
    -> HexHeartbeatCompletionDisposition
  {
    try transaction { try finish(completion, at: now, permitsExpiredLease: true) }
  }

  func finish(_ completion: HexHeartbeatCompletion, at now: Date, permitsExpiredLease: Bool) throws
    -> HexHeartbeatCompletionDisposition
  {
    try validate(now)
    try validate(completion.lease)
    try validate(completion.outcome)
    try validate(completion.nextDueAt)
    guard completion.outcome.completedAt <= now,
      completion.outcome.occurrence == completion.lease.occurrence
    else {
      throw HexHeartbeatStoreError.invalidCompletion(
        "The completion must match its occurrence and cannot be in the future.")
    }
    guard let previous = try receipt(for: completion.lease.occurrence),
      previous.lease == completion.lease
    else {
      throw HexHeartbeatStoreError.staleLease
    }
    let replacement = HexHeartbeatOccurrenceReceipt(
      occurrence: previous.occurrence, scheduleName: previous.scheduleName, lease: previous.lease,
      outcome: completion.outcome, nextDueAtAfterCompletion: completion.nextDueAt,
      journal: completion.journal)
    _ = try validate(replacement)
    if previous.outcome != nil {
      guard previous == replacement else {
        throw HexHeartbeatStoreError.invalidCompletion(
          "This occurrence already has a different durable completion.")
      }
      return .alreadyCompleted
    }
    guard permitsExpiredLease || completion.lease.expiresAt > now else {
      throw HexHeartbeatStoreError.staleLease
    }
    try writeReceipt(replacement, inserting: false)
    // Completion remains durable after deletion; never mutate a different/recreated active lease.
    if var schedule = try schedule(for: previous.occurrence.scheduleID),
      schedule.activeLease == completion.lease
    {
      schedule.activeLease = nil
      schedule.lastOutcome = completion.outcome
      schedule.lastCompletedLeaseID = completion.lease.leaseID
      schedule.nextDueAt = completion.nextDueAt
      try writeSchedule(schedule)
    }
    return .completed
  }

  public func reconcileExpiredLeases(at now: Date) async throws -> HexHeartbeatStoreSnapshot {
    try validate(now)
    return try transaction {
      // Legacy rows have no trustworthy run ID to inspect. Linked rows, including deleted
      // schedules, are left pending for host recovery; expiry alone never overwrites known output.
      let rows = try database.rows(
        Self.receiptColumns
          + " WHERE is_terminal=0 AND run_id IS NULL AND expires_at<=? ORDER BY sequence LIMIT 256",
        [.real(now.timeIntervalSinceReferenceDate)], maximumRows: 256)
      for row in rows {
        let (_, receipt) = try decodeReceiptRow(row)
        guard let lease = receipt.lease else { throw SQLiteHexHeartbeatStoreError.corrupt }
        let schedule = try schedule(for: receipt.occurrence.scheduleID)
        let nextDueAt = schedule?.nextDueAfter(receipt.occurrence.dueAt, now: now) ?? now
        let outcome = HexHeartbeatOutcome(
          occurrence: receipt.occurrence, kind: .interrupted, completedAt: now,
          failure: HexHeartbeatFailure(
            code: .leaseExpired,
            message:
              "The legacy scheduled run expired without a persisted run identity. No work was restarted.",
            retryable: false))
        _ = try finish(
          HexHeartbeatCompletion(lease: lease, outcome: outcome, nextDueAt: nextDueAt),
          at: now, permitsExpiredLease: true)
      }
      return try readSnapshot()
    }
  }
}
