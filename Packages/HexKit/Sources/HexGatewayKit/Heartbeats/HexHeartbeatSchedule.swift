import Foundation

public struct HexHeartbeatSchedule: Codable, Equatable, Identifiable, Sendable {
  public let id: HexHeartbeatScheduleID
  public let name: String
  public let instruction: String
  public let intervalSeconds: TimeInterval
  public let maxCatchUpOccurrences: Int
  public var nextDueAt: Date
  public var isPaused: Bool
  public var lastOutcome: HexHeartbeatOutcome?
  public var activeLease: HexHeartbeatLease?
  /// The lease that durably committed `lastOutcome`. Keeping this separate from the outcome lets
  /// the store distinguish an exact idempotent retry from a completion submitted by a stale lease.
  public var lastCompletedLeaseID: UUID?

  public init(
    id: HexHeartbeatScheduleID = HexHeartbeatScheduleID(),
    name: String,
    instruction: String,
    intervalSeconds: TimeInterval,
    nextDueAt: Date,
    maxCatchUpOccurrences: Int = 1,
    isPaused: Bool = false,
    lastOutcome: HexHeartbeatOutcome? = nil,
    activeLease: HexHeartbeatLease? = nil,
    lastCompletedLeaseID: UUID? = nil
  ) throws {
    guard !name.isEmpty, name.utf8.count <= Self.maximumNameBytes else {
      throw HexHeartbeatStoreError.invalidSchedule(
        "A heartbeat name must contain between 1 and \(Self.maximumNameBytes) UTF-8 bytes."
      )
    }
    guard !instruction.isEmpty, instruction.utf8.count <= Self.maximumInstructionBytes else {
      throw HexHeartbeatStoreError.invalidSchedule(
        "A heartbeat instruction must contain between 1 and \(Self.maximumInstructionBytes) UTF-8 bytes."
      )
    }
    guard intervalSeconds.isFinite, intervalSeconds > 0,
      intervalSeconds <= Self.maximumIntervalSeconds
    else {
      throw HexHeartbeatStoreError.invalidSchedule(
        "A heartbeat interval must be finite, positive, and no longer than one year."
      )
    }
    guard nextDueAt.timeIntervalSinceReferenceDate.isFinite else {
      throw HexHeartbeatStoreError.invalidSchedule(
        "A heartbeat next-due date must be finite."
      )
    }
    guard (1...Self.maximumCatchUpOccurrences).contains(maxCatchUpOccurrences) else {
      throw HexHeartbeatStoreError.invalidSchedule(
        "A heartbeat catch-up limit must be between 1 and \(Self.maximumCatchUpOccurrences)."
      )
    }
    if let activeLease {
      guard activeLease.occurrence.scheduleID == id else {
        throw HexHeartbeatStoreError.invalidSchedule(
          "A heartbeat lease must belong to its schedule."
        )
      }
      guard activeLease.occurrence.dueAt == nextDueAt else {
        throw HexHeartbeatStoreError.invalidSchedule(
          "A heartbeat lease must identify the schedule's next due occurrence."
        )
      }
      guard activeLease.expiresAt > activeLease.claimedAt else {
        throw HexHeartbeatStoreError.invalidSchedule(
          "A heartbeat lease must expire after it is claimed."
        )
      }
    }
    if let lastOutcome {
      guard lastOutcome.occurrence.scheduleID == id else {
        throw HexHeartbeatStoreError.invalidSchedule(
          "A heartbeat outcome must belong to its schedule."
        )
      }
    }
    if lastCompletedLeaseID != nil {
      guard lastOutcome != nil else {
        throw HexHeartbeatStoreError.invalidSchedule(
          "A completed heartbeat lease requires a last outcome."
        )
      }
    }

    self.id = id
    self.name = name
    self.instruction = instruction
    self.intervalSeconds = intervalSeconds
    self.maxCatchUpOccurrences = maxCatchUpOccurrences
    self.nextDueAt = nextDueAt
    self.isPaused = isPaused
    self.lastOutcome = lastOutcome
    self.activeLease = activeLease
    self.lastCompletedLeaseID = lastCompletedLeaseID
  }

  public func occurrence(at dueAt: Date? = nil) -> HexHeartbeatOccurrenceID {
    HexHeartbeatOccurrenceID(scheduleID: id, dueAt: dueAt ?? nextDueAt)
  }

  func validated() throws -> Self {
    try Self(
      id: id,
      name: name,
      instruction: instruction,
      intervalSeconds: intervalSeconds,
      nextDueAt: nextDueAt,
      maxCatchUpOccurrences: maxCatchUpOccurrences,
      isPaused: isPaused,
      lastOutcome: lastOutcome,
      activeLease: activeLease,
      lastCompletedLeaseID: lastCompletedLeaseID
    )
  }

  public func nextDueAfter(_ occurrenceDueAt: Date, now: Date) -> Date {
    let firstFollowing = nextOccurrenceAfter(occurrenceDueAt)
    guard firstFollowing.timeIntervalSinceReferenceDate.isFinite else {
      return Date.distantFuture
    }
    guard firstFollowing <= now else {
      return firstFollowing
    }

    let elapsed = now.timeIntervalSince(firstFollowing)
    guard elapsed.isFinite, elapsed >= 0 else {
      return firstFollowing
    }
    let additionalIntervals = floor(elapsed / intervalSeconds) + 1
    let offset = additionalIntervals * intervalSeconds
    guard offset.isFinite else {
      return Date.distantFuture
    }
    let candidate = firstFollowing.addingTimeInterval(offset)
    return candidate.timeIntervalSinceReferenceDate.isFinite ? candidate : Date.distantFuture
  }

  public func nextOccurrenceAfter(_ occurrenceDueAt: Date) -> Date {
    let candidate = occurrenceDueAt.addingTimeInterval(intervalSeconds)
    return candidate.timeIntervalSinceReferenceDate.isFinite ? candidate : Date.distantFuture
  }

  static let maximumNameBytes = 512
  static let maximumInstructionBytes = 64 * 1_024
  static let maximumIntervalSeconds: TimeInterval = 365 * 24 * 60 * 60
  static let maximumCatchUpOccurrences = 16
}
