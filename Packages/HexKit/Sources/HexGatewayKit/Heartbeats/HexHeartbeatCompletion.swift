import Foundation

public struct HexHeartbeatCompletion: Sendable {
  public let lease: HexHeartbeatLease
  public let outcome: HexHeartbeatOutcome
  public let nextDueAt: Date

  public init(
    lease: HexHeartbeatLease,
    outcome: HexHeartbeatOutcome,
    nextDueAt: Date
  ) {
    self.lease = lease
    self.outcome = outcome
    self.nextDueAt = nextDueAt
  }
}
