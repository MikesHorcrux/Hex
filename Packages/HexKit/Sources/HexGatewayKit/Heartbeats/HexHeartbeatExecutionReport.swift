public struct HexHeartbeatExecutionReport: Equatable, Sendable {
  public let occurrence: HexHeartbeatOccurrenceID
  public let outcome: HexHeartbeatOutcome

  public init(occurrence: HexHeartbeatOccurrenceID, outcome: HexHeartbeatOutcome) {
    self.occurrence = occurrence
    self.outcome = outcome
  }
}
