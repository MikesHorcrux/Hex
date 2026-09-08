public enum HexHeartbeatRunInspection: Equatable, Sendable {
  /// The current resident still owns this run. Lease expiry is not permission to duplicate it.
  case running
  case terminal(outcome: HexHeartbeatOutcome, journal: HexHeartbeatRunJournalIdentity)
  /// No terminal evidence or current resident ownership could be established. Effects are unknown.
  case unknown
}
