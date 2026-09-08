/// An append-only, per-run event journal. Appending atomically assigns the event ID, timestamp, and
/// sequence. Each run starts with exactly one `runStarted` record at sequence 1 and increases
/// monotonically; duplicate starts are rejected atomically. A successful append return is the
/// cancellation commit point and means the record is durable: cancellation observed after that
/// commit must not turn the successful append into a thrown `CancellationError`.
///
/// Reads are always bounded, return ascending records, treat `after` as exclusive, apply `limit`,
/// and return an empty array for an unknown run. Implementations must otherwise propagate task
/// cancellation and `CancellationError` without wrapping it.
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
