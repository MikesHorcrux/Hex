import HexCore
import HexIPC
import HexPersistence

/// A read-only bridge to the same exclusively owned journal used by the runtime. It does not open
/// another database connection, repair runs, or execute the runtime during a recovery request.
struct HexGatewayJournalHistoryReader: HexGatewayRunHistoryReading {
  let journal: SQLiteAgentEventJournal

  func snapshot(for runID: AgentRunID) async throws -> GatewayJournalRunSnapshot? {
    guard let snapshot = try await journal.runSnapshot(for: runID) else { return nil }
    return GatewayJournalRunSnapshot(
      runID: snapshot.runID, firstEventID: snapshot.firstEventID,
      latestSequence: snapshot.latestSequence, terminalRecord: snapshot.terminalRecord)
  }

  func records(for runID: AgentRunID, after: UInt64, through: UInt64, limit: Int, maximumBytes: Int)
    async throws -> [AgentEventRecord]
  {
    try await journal.recoveryRecords(
      for: runID, after: after, through: through, limit: limit, maximumBytes: maximumBytes)
  }
}
