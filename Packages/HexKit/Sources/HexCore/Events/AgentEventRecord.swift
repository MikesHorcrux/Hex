import Foundation

public struct AgentEventRecord: Identifiable, Codable, Equatable, Sendable {
  public let id: AgentEventID
  public let runID: AgentRunID
  public let sequence: UInt64
  public let timestamp: Date
  public let schemaVersion: UInt16
  public let event: AgentEvent

  public init(
    id: AgentEventID,
    runID: AgentRunID,
    sequence: UInt64,
    timestamp: Date,
    schemaVersion: UInt16 = 1,
    event: AgentEvent
  ) {
    self.id = id
    self.runID = runID
    self.sequence = sequence
    self.timestamp = timestamp
    self.schemaVersion = schemaVersion
    self.event = event
  }
}
