import Foundation

public struct HexHeartbeatCompletion: Codable, Equatable, Sendable {
  public let lease: HexHeartbeatLease
  public let outcome: HexHeartbeatOutcome
  public let nextDueAt: Date
  public let journal: HexHeartbeatRunJournalIdentity?

  public init(
    lease: HexHeartbeatLease,
    outcome: HexHeartbeatOutcome,
    nextDueAt: Date,
    journal: HexHeartbeatRunJournalIdentity? = nil
  ) {
    self.lease = lease
    self.outcome = outcome
    self.nextDueAt = nextDueAt
    self.journal = journal
  }
}
