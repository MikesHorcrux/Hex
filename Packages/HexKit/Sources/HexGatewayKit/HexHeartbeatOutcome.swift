import Foundation

public struct HexHeartbeatOutcome: Codable, Equatable, Sendable {
  public let occurrence: HexHeartbeatOccurrenceID
  public let kind: HexHeartbeatOutcomeKind
  public let completedAt: Date
  public let failure: HexHeartbeatFailure?

  public init(
    occurrence: HexHeartbeatOccurrenceID,
    kind: HexHeartbeatOutcomeKind,
    completedAt: Date,
    failure: HexHeartbeatFailure? = nil
  ) {
    self.occurrence = occurrence
    self.kind = kind
    self.completedAt = completedAt
    self.failure = failure
  }
}
