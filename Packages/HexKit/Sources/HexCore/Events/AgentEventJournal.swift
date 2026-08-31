/// An append-only, per-run event journal. Appending atomically assigns the event ID, timestamp, and
/// sequence. Each run starts at sequence 1 and increases monotonically. A successful append return
/// means the record is durable. Reads are always bounded, return ascending records, treat `after` as
/// exclusive, and apply `limit`. Implementations must propagate task cancellation and
/// `CancellationError` without wrapping it.
public protocol AgentEventJournal: Sendable {
  func append(
    _ event: AgentEvent,
    to runID: AgentRunID
  ) async throws -> AgentEventRecord

  func records(
    for runID: AgentRunID,
    after sequence: UInt64?,
    limit: Int
  ) async throws -> [AgentEventRecord]
}
