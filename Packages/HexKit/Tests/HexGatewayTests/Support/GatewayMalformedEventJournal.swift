import Foundation
import HexCore

actor GatewayMalformedEventJournal: AgentEventJournal {
  func append(
    _ event: AgentEvent,
    to runID: AgentRunID
  ) async throws -> AgentEventRecord {
    _ = runID
    return AgentEventRecord(
      id: AgentEventID(),
      runID: AgentRunID(),
      sequence: 1,
      timestamp: Date(),
      event: event
    )
  }

  func records(
    for runID: AgentRunID,
    after sequence: UInt64?,
    limit: Int
  ) async throws -> [AgentEventRecord] {
    _ = runID
    _ = sequence
    _ = limit
    return []
  }
}
