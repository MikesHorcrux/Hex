import Foundation

/// The resident-to-app projection of one heartbeat schedule. Runtime leases and occurrence
/// identities never cross this boundary.
public struct GatewayHeartbeatSchedule: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let name: String
  public let instruction: String
  public let intervalSeconds: TimeInterval
  public let nextDueAt: Date
  public let maxCatchUpOccurrences: Int
  public let isPaused: Bool
  public let lastOutcome: GatewayHeartbeatOutcome?

  public init(
    id: UUID,
    name: String,
    instruction: String,
    intervalSeconds: TimeInterval,
    nextDueAt: Date,
    maxCatchUpOccurrences: Int,
    isPaused: Bool,
    lastOutcome: GatewayHeartbeatOutcome? = nil
  ) {
    self.id = id
    self.name = name
    self.instruction = instruction
    self.intervalSeconds = intervalSeconds
    self.nextDueAt = nextDueAt
    self.maxCatchUpOccurrences = maxCatchUpOccurrences
    self.isPaused = isPaused
    self.lastOutcome = lastOutcome
  }

  public func validated() throws -> Self {
    try Self.validate(
      id: id,
      name: name,
      instruction: instruction,
      intervalSeconds: intervalSeconds,
      nextDueAt: nextDueAt,
      maxCatchUpOccurrences: maxCatchUpOccurrences
    )
    _ = try lastOutcome?.validated()
    return self
  }

  static func validate(
    id: UUID,
    name: String,
    instruction: String,
    intervalSeconds: TimeInterval,
    nextDueAt: Date,
    maxCatchUpOccurrences: Int
  ) throws {
    guard id != Self.zeroUUID else {
      throw GatewayFailure(
        code: .malformedPayload,
        message: "A heartbeat schedule must contain a non-zero identity."
      )
    }
    guard !name.isEmpty, name.utf8.count <= Self.maximumNameBytes else {
      throw GatewayFailure(
        code: .malformedPayload,
        message: "A heartbeat name must contain between 1 and \(Self.maximumNameBytes) UTF-8 bytes."
      )
    }
    guard !instruction.isEmpty, instruction.utf8.count <= Self.maximumInstructionBytes else {
      throw GatewayFailure(
        code: .malformedPayload,
        message:
          "A heartbeat instruction must contain between 1 and \(Self.maximumInstructionBytes) UTF-8 bytes."
      )
    }
    guard intervalSeconds.isFinite,
      intervalSeconds > 0,
      intervalSeconds <= Self.maximumIntervalSeconds
    else {
      throw GatewayFailure(
        code: .malformedPayload,
        message: "A heartbeat interval must be finite, positive, and no longer than one year."
      )
    }
    guard nextDueAt.timeIntervalSinceReferenceDate.isFinite else {
      throw GatewayFailure(
        code: .malformedPayload,
        message: "A heartbeat next-due date must be finite."
      )
    }
    guard (1...Self.maximumCatchUpOccurrences).contains(maxCatchUpOccurrences) else {
      throw GatewayFailure(
        code: .malformedPayload,
        message:
          "A heartbeat catch-up limit must be between 1 and \(Self.maximumCatchUpOccurrences)."
      )
    }
  }

  public static let zeroUUID = UUID(
    uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
  )
  public static let maximumNameBytes = 512
  public static let maximumInstructionBytes = 64 * 1_024
  public static let maximumIntervalSeconds: TimeInterval = 365 * 24 * 60 * 60
  public static let maximumCatchUpOccurrences = 16
}
