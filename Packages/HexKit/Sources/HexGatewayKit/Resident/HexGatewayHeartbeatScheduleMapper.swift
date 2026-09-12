import HexIPC

/// Converts between resident scheduler values and the redacted app-facing heartbeat contracts.
/// Runtime leases and occurrence identities are deliberately never represented in the wire values.
public enum HexGatewayHeartbeatScheduleMapper: Sendable {
  public static func schedule(
    from request: GatewayHeartbeatScheduleRequest
  ) throws -> HexHeartbeatSchedule {
    let request = try request.validated()
    return try HexHeartbeatSchedule(
      id: HexHeartbeatScheduleID(rawValue: request.id),
      name: request.name,
      instruction: request.instruction,
      intervalSeconds: request.intervalSeconds,
      nextDueAt: request.nextDueAt,
      maxCatchUpOccurrences: request.maxCatchUpOccurrences,
      isPaused: request.isPaused
    )
  }

  public static func list(
    from snapshot: HexHeartbeatStoreSnapshot
  ) throws -> GatewayHeartbeatScheduleList {
    try GatewayHeartbeatScheduleList(
      schedules: snapshot.schedules.map(schedule(from:)),
      isPaused: snapshot.isPaused
    ).validated()
  }

  private static func schedule(
    from schedule: HexHeartbeatSchedule
  ) -> GatewayHeartbeatSchedule {
    GatewayHeartbeatSchedule(
      id: schedule.id.rawValue,
      name: schedule.name,
      instruction: schedule.instruction,
      intervalSeconds: schedule.intervalSeconds,
      nextDueAt: schedule.nextDueAt,
      maxCatchUpOccurrences: schedule.maxCatchUpOccurrences,
      isPaused: schedule.isPaused,
      lastOutcome: schedule.lastOutcome.map(outcome(from:))
    )
  }

  private static func outcome(
    from outcome: HexHeartbeatOutcome
  ) -> GatewayHeartbeatOutcome {
    GatewayHeartbeatOutcome(
      kind: outcomeKind(from: outcome.kind),
      completedAt: outcome.completedAt,
      failureMessage: outcome.failure?.message
    )
  }

  private static func outcomeKind(
    from kind: HexHeartbeatOutcomeKind
  ) -> GatewayHeartbeatOutcomeKind {
    switch kind {
    case .succeeded:
      .succeeded
    case .failed:
      .failed
    case .cancelled:
      .cancelled
    case .skipped:
      .skipped
    case .interrupted:
      .interrupted
    }
  }
}
