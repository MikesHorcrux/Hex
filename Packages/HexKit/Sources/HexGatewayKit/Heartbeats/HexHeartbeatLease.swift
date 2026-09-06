import Foundation
import HexCore

public struct HexHeartbeatLease: Codable, Equatable, Sendable {
  public let leaseID: UUID
  public let occurrence: HexHeartbeatOccurrenceID
  public let claimedAt: Date
  public let expiresAt: Date
  /// Allocated and persisted before dispatch. Missing only for legacy, unlinked leases.
  public let runID: AgentRunID?

  public init(
    leaseID: UUID = UUID(),
    occurrence: HexHeartbeatOccurrenceID,
    claimedAt: Date,
    expiresAt: Date,
    runID: AgentRunID? = nil
  ) {
    self.leaseID = leaseID
    self.occurrence = occurrence
    self.claimedAt = claimedAt
    self.expiresAt = expiresAt
    self.runID = runID
  }
}
