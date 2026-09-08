import Foundation

extension HexHeartbeatScheduler {
  /// Discovery only: never starts, retries, acknowledges, or reattaches a run.
  public func receipts(
    scheduleID: HexHeartbeatScheduleID? = nil,
    after cursor: HexHeartbeatReceiptCursor? = nil,
    limit: Int = 20
  ) async throws -> HexHeartbeatReceiptPage {
    guard let history = store as? any HexHeartbeatHistoryStore else {
      throw HexHeartbeatSchedulerError.invalidConfiguration(
        "This scheduler has no retained run-history store.")
    }
    return try await history.receipts(scheduleID: scheduleID, after: cursor, limit: limit)
  }

  func refreshReceiptWakeDate() async throws {
    nextReceiptWakeAt = try await (store as? any HexHeartbeatHistoryStore)?
      .nextPendingReceiptExpiry()
  }

  func verifiedCompletion(
    lease: HexHeartbeatLease, outcome: HexHeartbeatOutcome, nextDueAt: Date
  ) async throws -> HexHeartbeatCompletion? {
    guard store is any HexHeartbeatHistoryStore, let runInspector else {
      return HexHeartbeatCompletion(lease: lease, outcome: outcome, nextDueAt: nextDueAt)
    }
    switch try await runInspector.inspect(lease) {
    case .terminal(let saved, let journal):
      // Keep the host's more actionable approval explanation when both report the same failure.
      // A durable success wins over a dropped final acknowledgement or observation timeout.
      let resolved =
        saved.kind == .failed && outcome.failure?.code == .authorizationRequired
        ? HexHeartbeatOutcome(
          occurrence: saved.occurrence, kind: saved.kind, completedAt: saved.completedAt,
          failure: outcome.failure)
        : saved
      return HexHeartbeatCompletion(
        lease: lease, outcome: resolved, nextDueAt: nextDueAt, journal: journal)
    case .running:
      // A timeout or cancellation acknowledgement is not proof that admitted work has stopped.
      // Keep its exact lease pending; recovery inspects it without dispatching it again.
      return nil
    case .unknown:
      // Busy is an explicit rejection before admission. Every other missing terminal leaves the
      // durable identity available for recovery instead of inventing an immutable final result.
      guard outcome.failure?.code == .gatewayBusy else { return nil }
      return HexHeartbeatCompletion(lease: lease, outcome: outcome, nextDueAt: nextDueAt)
    }
  }

  func finishExecution(
    lease: HexHeartbeatLease, outcome: HexHeartbeatOutcome, nextDueAt: Date
  ) async throws -> HexHeartbeatCompletion? {
    // Stop cancels execution, not the durable receipt for work already observed. Await this fresh
    // task so shutdown cannot return while a known terminal result is still only in memory.
    try await Task.detached { [self] () throws -> HexHeartbeatCompletion? in
      guard
        let completion = try await verifiedCompletion(
          lease: lease, outcome: outcome, nextDueAt: nextDueAt)
      else { return nil }
      _ = try await persistCompletion(completion, at: clock.now)
      return completion
    }.value
  }

  func persistCompletion(_ completion: HexHeartbeatCompletion, at now: Date) async throws
    -> HexHeartbeatCompletionDisposition
  {
    if let history = store as? any HexHeartbeatHistoryStore,
      completion.journal != nil, completion.lease.expiresAt <= now
    {
      return try await history.reconcile(completion, at: now)
    }
    return try await store.complete(completion, at: now)
  }

  func reconciledSnapshot(at now: Date) async throws -> HexHeartbeatStoreSnapshot {
    guard let history = store as? any HexHeartbeatHistoryStore else {
      return try await store.reconcileExpiredLeases(at: now)
    }
    nextRecoveryCheckAt = nil
    let expired = try await history.expiredReceipts(at: now, limit: 100)
    // Capture schedule timing only for advancement. The store rechecks exact lease ownership
    // transactionally after inspection, so a concurrently deleted/replaced schedule is untouched.
    let snapshot = try await store.load()
    for receipt in expired {
      try Task.checkCancellation()
      guard let lease = receipt.lease else { continue }
      let inspection: HexHeartbeatRunInspection
      if lease.runID == nil {
        inspection = .unknown
      } else if let runInspector {
        inspection = try await runInspector.inspect(lease)
      } else {
        throw HexHeartbeatSchedulerError.invalidConfiguration(
          "The saved scheduled run cannot be inspected. Its lease has been preserved.")
      }
      let outcome: HexHeartbeatOutcome
      let journal: HexHeartbeatRunJournalIdentity?
      switch inspection {
      case .running:
        nextRecoveryCheckAt = now.addingTimeInterval(5)
        continue
      case .terminal(let saved, let identity):
        outcome = saved
        journal = identity
      case .unknown:
        outcome = HexHeartbeatOutcome(
          occurrence: lease.occurrence, kind: .interrupted, completedAt: now,
          failure: HexHeartbeatFailure(
            code: .leaseExpired,
            message:
              "The scheduled run's lease expired without a verified result. Actions may have occurred; Hex has not repeated this occurrence.",
            retryable: false))
        journal = nil
      }
      let schedule = snapshot.schedules.first { $0.id == lease.occurrence.scheduleID }
      let nextDueAt =
        schedule?.nextDueAfter(lease.occurrence.dueAt, now: now)
        ?? now.addingTimeInterval(1)
      _ = try await history.reconcile(
        HexHeartbeatCompletion(
          lease: lease, outcome: outcome, nextDueAt: nextDueAt, journal: journal), at: now)
    }
    try await refreshReceiptWakeDate()
    if expired.count == 100, nextRecoveryCheckAt == nil {
      // A bounded batch leaves additional receipts for the next resident iteration.
      nextRecoveryCheckAt = now.addingTimeInterval(1)
    }
    return try await store.load()
  }
}
