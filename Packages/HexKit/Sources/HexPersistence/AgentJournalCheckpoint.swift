import Foundation
import HexCore

/// An immutable snapshot associated with an existing durable event sequence.
public struct AgentJournalCheckpoint: Codable, Equatable, Sendable {
  public let runID: AgentRunID
  public let throughSequence: UInt64
  public let createdAt: Date
  public let schemaVersion: UInt16
  public let snapshot: JSONValue

  public init(
    runID: AgentRunID,
    throughSequence: UInt64,
    createdAt: Date,
    schemaVersion: UInt16 = 1,
    snapshot: JSONValue
  ) {
    self.runID = runID
    self.throughSequence = throughSequence
    self.createdAt = createdAt
    self.schemaVersion = schemaVersion
    self.snapshot = snapshot
  }
}
