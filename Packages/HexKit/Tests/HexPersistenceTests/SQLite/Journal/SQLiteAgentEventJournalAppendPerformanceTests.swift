import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("SQLite append hot-path performance")
struct SQLiteAgentEventJournalAppendPerformanceTests {
  @Test
  func unrelatedHistoryDoesNotScaleStreamingAppendAndReadLatency() async throws {
    let sparse = try await makeJournal(unrelatedRunCount: 0)
    let dense = try await makeJournal(unrelatedRunCount: 900)
    defer {
      JournalTestSupport.removeTemporaryDirectory(sparse.directory)
      JournalTestSupport.removeTemporaryDirectory(dense.directory)
    }

    let sparseDuration = try await measuredStreamingAppends(to: sparse.journal)
    let denseDuration = try await measuredStreamingAppends(to: dense.journal)

    print(
      "Journal streaming append/read: sparse=\(sparseDuration), 900 prior runs=\(denseDuration)")
    #expect(denseDuration < sparseDuration + .milliseconds(500))

    try await sparse.journal.close()
    try await dense.journal.close()
  }

  @Test
  func activeRunStreamingLatencyRemainsBoundedAfterOneThousandDeltas() async throws {
    let fixture = try await makeJournal(unrelatedRunCount: 0)
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    let runID = AgentRunID()
    _ = try await fixture.journal.append(.runStarted, to: runID)
    _ = try await fixture.journal.append(
      .messageAppended(
        Message(role: .user, content: [.text(String(repeating: "schema", count: 16_000))])),
      to: runID
    )
    let initialDuration = try await measuredDeltas(
      to: fixture.journal,
      runID: runID,
      includingRead: false
    )
    for _ in 0..<1_000 {
      _ = try await fixture.journal.append(.inferenceEvent(.textDelta("token")), to: runID)
    }
    let expandedDuration = try await measuredDeltas(
      to: fixture.journal,
      runID: runID,
      includingRead: false
    )

    print("Journal active run: initial=\(initialDuration), 1000 deltas=\(expandedDuration)")
    #expect(expandedDuration < initialDuration + .milliseconds(500))
    try await fixture.journal.close()
  }

  private func makeJournal(
    unrelatedRunCount: Int
  ) async throws -> (directory: URL, journal: SQLiteAgentEventJournal) {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    let configuration = JournalTestSupport.configuration(in: directory)
    let emptyJournal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    try await emptyJournal.close()

    if unrelatedRunCount > 0 {
      try seedTerminalRuns(
        count: unrelatedRunCount,
        at: configuration.databaseURL
      )
    }

    return (
      directory,
      try await SQLiteAgentEventJournal.open(configuration: configuration)
    )
  }

  private func measuredStreamingAppends(
    to journal: SQLiteAgentEventJournal
  ) async throws -> Duration {
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    return try await measuredDeltas(to: journal, runID: runID)
  }

  private func measuredDeltas(
    to journal: SQLiteAgentEventJournal,
    runID: AgentRunID,
    includingRead: Bool = true
  ) async throws -> Duration {
    let clock = ContinuousClock()
    let startedAt = clock.now
    for index in 0..<10 {
      let record = try await journal.append(
        .inferenceEvent(.textDelta("streaming-token-\(index)")),
        to: runID
      )
      if includingRead {
        let page = try await journal.records(for: runID, after: record.sequence - 1, limit: 1)
        #expect(page == [record])
      }
    }
    return startedAt.duration(to: clock.now)
  }

  private func seedTerminalRuns(
    count: Int,
    at databaseURL: URL
  ) throws {
    let started = AgentEvent.runStarted
    let completed = AgentEvent.runCompleted
    let startedPayload = try hexadecimalString(AgentEventCodec.encode(event: started))
    let completedPayload = try hexadecimalString(AgentEventCodec.encode(event: completed))
    try JournalTestSupport.execute(
      """
      BEGIN IMMEDIATE;
      WITH RECURSIVE numbers(value) AS (
        VALUES(1)
        UNION ALL
        SELECT value + 1 FROM numbers WHERE value < \(count)
      )
      INSERT INTO runs (
        run_id, next_sequence, terminal_sequence, created_at_us, updated_at_us
      )
      SELECT
        printf('%08X-0000-4000-8000-%012X', value, value),
        3,
        2,
        value,
        value
      FROM numbers;

      WITH RECURSIVE numbers(value) AS (
        VALUES(1)
        UNION ALL
        SELECT value + 1 FROM numbers WHERE value < \(count)
      )
      INSERT INTO event_records (
        event_id, run_id, sequence, timestamp_us, record_schema_version, kind, tool_call_id,
        payload
      )
      SELECT
        printf('%08X-0001-4000-8000-%012X', value, value),
        printf('%08X-0000-4000-8000-%012X', value, value),
        1,
        value,
        \(AgentEventCodec.recordSchemaVersion),
        '\(started.journalKind)',
        NULL,
        X'\(startedPayload)'
      FROM numbers
      UNION ALL
      SELECT
        printf('%08X-0002-4000-8000-%012X', value, value),
        printf('%08X-0000-4000-8000-%012X', value, value),
        2,
        value,
        \(AgentEventCodec.recordSchemaVersion),
        '\(completed.journalKind)',
        NULL,
        X'\(completedPayload)'
      FROM numbers;
      COMMIT;
      """,
      at: databaseURL
    )
  }
  private func hexadecimalString(_ data: Data) -> String {
    data.map { String(format: "%02X", $0) }.joined()
  }
}
