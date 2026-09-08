import HexIPC

/// Projects occurrence metadata only. Original messages and artifacts remain in the run journal.
public enum HexGatewayHeartbeatRunMapper: Sendable {
  public static func cursor(from request: GatewayHeartbeatRunListRequest) throws
    -> HexHeartbeatReceiptCursor?
  {
    let request = try request.validated()
    return request.cursor.map {
      HexHeartbeatReceiptCursor(
        storeID: $0.storeID, scheduleID: $0.scheduleID.map(HexHeartbeatScheduleID.init(rawValue:)),
        highWaterSequence: $0.highWaterSequence, beforeSequence: $0.beforeSequence)
    }
  }

  public static func page(
    from page: HexHeartbeatReceiptPage, for request: GatewayHeartbeatRunListRequest
  ) throws -> GatewayHeartbeatRunPage {
    if let previous = request.cursor, previous.storeID != page.storeID {
      throw GatewayFailure(
        code: .invalidCursor, message: "The scheduled run history store changed.")
    }
    if let next = page.nextCursor, next.storeID != page.storeID {
      throw GatewayFailure(
        code: .invalidCursor, message: "The scheduled run history cursor changed stores.")
    }
    return try GatewayHeartbeatRunPage(
      storeID: page.storeID,
      runs: page.receipts.map(run(from:)),
      nextCursor: page.nextCursor.map {
        GatewayHeartbeatRunCursor(
          storeID: $0.storeID, scheduleID: $0.scheduleID?.rawValue,
          highWaterSequence: $0.highWaterSequence, beforeSequence: $0.beforeSequence)
      }
    ).validated(for: request)
  }

  private static func run(from receipt: HexHeartbeatOccurrenceReceipt) -> GatewayHeartbeatRun {
    GatewayHeartbeatRun(
      scheduleID: receipt.occurrence.scheduleID.rawValue, dueAt: receipt.occurrence.dueAt,
      scheduleName: receipt.scheduleName, runID: receipt.runID,
      claimedAt: receipt.lease?.claimedAt, expiresAt: receipt.lease?.expiresAt,
      outcome: receipt.outcome.map {
        GatewayHeartbeatOutcome(
          kind: kind(from: $0.kind), completedAt: $0.completedAt,
          failureMessage: $0.failure?.message)
      },
      journal: receipt.journal.map {
        GatewayHeartbeatRunJournalIdentity(
          runID: $0.runID, firstEventID: $0.firstEventID,
          terminalSequence: $0.terminalSequence)
      })
  }

  private static func kind(from kind: HexHeartbeatOutcomeKind) -> GatewayHeartbeatOutcomeKind {
    switch kind {
    case .succeeded: .succeeded
    case .failed: .failed
    case .cancelled: .cancelled
    case .skipped: .skipped
    case .interrupted: .interrupted
    }
  }
}
