import Foundation

/// The app-to-resident configuration used when adding a heartbeat. It intentionally excludes
/// outcome and lease state so a caller cannot inject resident execution history.
public struct GatewayHeartbeatScheduleRequest: Codable, Equatable, Sendable {
  public let id: UUID
  public let name: String
  public let instruction: String
  public let intervalSeconds: TimeInterval
  public let nextDueAt: Date
  public let maxCatchUpOccurrences: Int
  public let isPaused: Bool

  public init(
    id: UUID,
    name: String,
    instruction: String,
    intervalSeconds: TimeInterval,
    nextDueAt: Date,
    maxCatchUpOccurrences: Int = 1,
    isPaused: Bool = false
  ) {
    self.id = id
    self.name = name
    self.instruction = instruction
    self.intervalSeconds = intervalSeconds
    self.nextDueAt = nextDueAt
    self.maxCatchUpOccurrences = maxCatchUpOccurrences
    self.isPaused = isPaused
  }

  public func validated() throws -> Self {
    try GatewayHeartbeatSchedule.validate(
      id: id,
      name: name,
      instruction: instruction,
      intervalSeconds: intervalSeconds,
      nextDueAt: nextDueAt,
      maxCatchUpOccurrences: maxCatchUpOccurrences
    )
    return self
  }
}
