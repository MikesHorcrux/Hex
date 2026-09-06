import Foundation
import HexCore

/// Compact occurrence metadata. A missing outcome is not proof a worker is still running; query
/// recoverRun for live state. Messages and saved-output references remain in the original journal.
public struct GatewayHeartbeatRun: Codable, Equatable, Sendable {
  public let scheduleID: UUID
  public let dueAt: Date
  public let scheduleName: String
  public let runID: AgentRunID?
  public let claimedAt: Date?
  public let expiresAt: Date?
  public let outcome: GatewayHeartbeatOutcome?
  public let journal: GatewayHeartbeatRunJournalIdentity?

  public init(
    scheduleID: UUID, dueAt: Date, scheduleName: String, runID: AgentRunID? = nil,
    claimedAt: Date? = nil, expiresAt: Date? = nil, outcome: GatewayHeartbeatOutcome? = nil,
    journal: GatewayHeartbeatRunJournalIdentity? = nil
  ) {
    self.scheduleID = scheduleID
    self.dueAt = dueAt
    self.scheduleName = scheduleName
    self.runID = runID
    self.claimedAt = claimedAt
    self.expiresAt = expiresAt
    self.outcome = outcome
    self.journal = journal
  }

  public func validated() throws -> Self {
    try GatewayRunRecoveryValidation.identity(scheduleID)
    if let runID { try GatewayRunRecoveryValidation.identity(runID.rawValue) }
    guard dueAt.timeIntervalSinceReferenceDate.isFinite,
      !scheduleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      scheduleName.utf8.count <= 512,
      (claimedAt == nil) == (expiresAt == nil)
    else { throw Self.malformed() }
    if let claimedAt, let expiresAt {
      guard claimedAt.timeIntervalSinceReferenceDate.isFinite,
        expiresAt.timeIntervalSinceReferenceDate.isFinite, expiresAt > claimedAt
      else { throw Self.malformed() }
    }
    _ = try outcome?.validated()
    if let journal {
      _ = try journal.validated()
      guard journal.runID == runID, outcome != nil else { throw Self.malformed() }
    }
    return self
  }

  private static func malformed() -> GatewayFailure {
    GatewayFailure(code: .malformedPayload, message: "The scheduled run receipt is inconsistent.")
  }
}
