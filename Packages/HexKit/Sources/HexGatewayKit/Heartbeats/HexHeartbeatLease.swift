import Foundation

public struct HexHeartbeatLease: Codable, Equatable, Sendable {
  public let leaseID: UUID
  public let occurrence: HexHeartbeatOccurrenceID
  public let claimedAt: Date
  public let expiresAt: Date

  public init(
    leaseID: UUID = UUID(),
    occurrence: HexHeartbeatOccurrenceID,
    claimedAt: Date,
    expiresAt: Date
  ) {
    self.leaseID = leaseID
    self.occurrence = occurrence
    self.claimedAt = claimedAt
    self.expiresAt = expiresAt
  }
}
