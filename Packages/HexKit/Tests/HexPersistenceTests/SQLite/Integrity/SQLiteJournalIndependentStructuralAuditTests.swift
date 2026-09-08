import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("Independent persistence structural audit")
struct SQLiteJournalIndependentStructuralAuditTests {
  @Test
  func physicalPageBudgetIsAdmittedBeforeFullIntegrityVerification() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let initial = try await SQLiteAgentEventJournal.open(
      configuration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
    )
    let runID = AgentRunID()
    _ = try await initial.append(.runStarted, to: runID)
    _ = try await initial.append(.runCompleted, to: runID)
    try await initial.close()

    let physicalBytes = try JournalTestSupport.withConnection(at: databaseURL) { connection in
      let pageSize = try connection.scalarInt64("PRAGMA page_size")
      let pageCount = try connection.scalarInt64("PRAGMA page_count")
      return Int(pageSize * pageCount)
    }
    let exact = try await SQLiteAgentEventJournal.open(
      configuration: SQLiteAgentEventJournalConfiguration(
        databaseURL: databaseURL,
        maximumDatabaseBytes: physicalBytes
      )
    )
    try await exact.close()

    do {
      let undersized = try await SQLiteAgentEventJournal.open(
        configuration: SQLiteAgentEventJournalConfiguration(
          databaseURL: databaseURL,
          maximumDatabaseBytes: physicalBytes - 1
        )
      )
      try await undersized.close()
      Issue.record("Open scanned a database larger than its configured physical page budget.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(
        error
          == .databaseSizeLimitExceeded(
            actual: physicalBytes,
            maximum: physicalBytes - 1
          )
      )
    }
  }

  @Test
  func openRejectsRequiredIndexRedirectedToAnOrphanBTree() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
    )
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    _ = try await journal.append(.runCompleted, to: runID)
    try await journal.close()

    let mutator = Process()
    mutator.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    mutator.arguments = [
      databaseURL.path,
      """
      CREATE INDEX orphan_source_idx
      ON event_records (run_id, kind, tool_call_id)
      WHERE sequence = 1;
      PRAGMA writable_schema = ON;
      UPDATE sqlite_schema
      SET rootpage = (
        SELECT rootpage FROM sqlite_schema WHERE name = 'orphan_source_idx'
      )
      WHERE name = 'event_records_run_kind_tool_call_idx';
      DELETE FROM sqlite_schema WHERE name = 'orphan_source_idx';
      PRAGMA writable_schema = OFF;
      """,
    ]
    try mutator.run()
    mutator.waitUntilExit()
    #expect(mutator.terminationReason == .exit)
    #expect(mutator.terminationStatus == 0)

    let integrityResult = try JournalTestSupport.withConnection(at: databaseURL) { connection in
      try connection.scalarText("PRAGMA integrity_check", maximumBytes: 4_096)
    }
    #expect(integrityResult != "ok")
    let indexedCount = try JournalTestSupport.scalarInt64(
      """
      SELECT COUNT(*) FROM event_records INDEXED BY event_records_run_kind_tool_call_idx
      WHERE run_id = '\(runID)'
      """,
      at: databaseURL
    )
    #expect(indexedCount == 1)
    #expect(
      try JournalTestSupport.scalarInt64("SELECT COUNT(*) FROM event_records", at: databaseURL) == 2
    )

    do {
      let reopened = try await SQLiteAgentEventJournal.open(
        configuration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
      )
      try await reopened.close()
      Issue.record(
        """
        Open admitted a required index redirected to an orphan b-tree; integrity_check was \
        \(integrityResult), indexed count was \(indexedCount), and table count was 2.
        """
      )
    } catch is SQLiteAgentEventJournalError {
      // Expected: physical schema consistency must fail closed.
    }
  }
}
