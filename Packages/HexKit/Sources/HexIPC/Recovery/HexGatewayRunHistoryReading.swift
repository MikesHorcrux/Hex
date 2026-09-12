import HexCore

/// Read-only durable store supplied by the composition root. Implementations must not admit runs,
/// execute tools, recover workers, or invent invocation IDs. Pages are bounded, contiguous prefixes.
public protocol HexGatewayRunHistoryReading: Sendable {
  func snapshot(for runID: AgentRunID) async throws -> GatewayJournalRunSnapshot?
  func records(for runID: AgentRunID, after: UInt64, through: UInt64, limit: Int, maximumBytes: Int)
    async throws -> [AgentEventRecord]
}
