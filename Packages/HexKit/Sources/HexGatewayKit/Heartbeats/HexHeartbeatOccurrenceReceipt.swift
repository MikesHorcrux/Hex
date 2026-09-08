import Foundation
import HexCore

/// Metadata retained independently of schedule lifetime. The journal owns all original output.
/// A missing lease identifies an imported historical outcome whose execution identity was lost.
public struct HexHeartbeatOccurrenceReceipt: Codable, Equatable, Sendable {
  public let occurrence: HexHeartbeatOccurrenceID
  public let scheduleName: String
  public let lease: HexHeartbeatLease?
  public let outcome: HexHeartbeatOutcome?
  public let nextDueAtAfterCompletion: Date?
  public let journal: HexHeartbeatRunJournalIdentity?
  public var runID: AgentRunID? { lease?.runID }

  public init(
    occurrence: HexHeartbeatOccurrenceID, scheduleName: String, lease: HexHeartbeatLease?,
    outcome: HexHeartbeatOutcome? = nil, nextDueAtAfterCompletion: Date? = nil,
    journal: HexHeartbeatRunJournalIdentity? = nil
  ) {
    self.occurrence = occurrence
    self.scheduleName = scheduleName
    self.lease = lease
    self.outcome = outcome
    self.nextDueAtAfterCompletion = nextDueAtAfterCompletion
    self.journal = journal
  }
}
