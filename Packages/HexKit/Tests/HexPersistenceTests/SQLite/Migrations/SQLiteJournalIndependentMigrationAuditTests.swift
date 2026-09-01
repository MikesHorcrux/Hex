import Foundation
import Testing

@testable import HexPersistence

@Suite("Independent persistence migration audit")
struct SQLiteJournalIndependentMigrationAuditTests {
  @Test
  func nonterminalMigrationRequiresReservedRecoveryRecord() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let fixture = try JournalTestSupport.createVersionTwoFixture(at: databaseURL)
    try JournalTestSupport.execute(
      """
      DELETE FROM event_records WHERE run_id = '\(fixture.runID)' AND sequence = 2;
      UPDATE runs
      SET next_sequence = 2, terminal_sequence = NULL
      WHERE run_id = '\(fixture.runID)';
      """,
      at: databaseURL
    )

    do {
      let journal = try await SQLiteAgentEventJournal.open(
        configuration: SQLiteAgentEventJournalConfiguration(
          databaseURL: databaseURL,
          maximumRecoveryRecordCount: 1
        )
      )
      try await journal.close()
      Issue.record("Migration consumed the record needed to recover its nonterminal run.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(error == .integrityRecordLimitExceeded(maximum: 1))
    }

    #expect(try JournalTestSupport.userVersion(at: databaseURL) == 2)
    #expect(try JournalTestSupport.tableExists("runs_v2", at: databaseURL) == false)
  }

  @Test
  func versionOnePayloadAdmissionFailureRollsBackEntireMigration() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let fixture = try JournalTestSupport.createVersionOneFixture(at: databaseURL)
    try JournalTestSupport.execute(
      "UPDATE event_records SET payload = X'FF' WHERE run_id = '\(fixture.runID)'",
      at: databaseURL
    )

    await expectRollback(databaseURL: databaseURL, expectedVersion: 1)
    #expect(try JournalTestSupport.tableExists("journal_checkpoints", at: databaseURL) == false)
  }

  @Test
  func versionTwoCheckpointAdmissionFailureRollsBackEntireMigration() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let fixture = try JournalTestSupport.createVersionTwoFixture(at: databaseURL)
    try JournalTestSupport.execute(
      """
      INSERT INTO journal_checkpoints VALUES ('\(fixture.runID)', 1, 1, 1, X'FF')
      """,
      at: databaseURL
    )

    await expectRollback(databaseURL: databaseURL, expectedVersion: 2)
    #expect(try JournalTestSupport.tableExists("runs_v2", at: databaseURL) == false)
  }

  @Test
  func versionTwoMalformedIntegerRollsBackEntireMigration() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let fixture = try JournalTestSupport.createVersionTwoFixture(at: databaseURL)
    try JournalTestSupport.execute(
      "UPDATE runs SET next_sequence = 'not-an-integer' WHERE run_id = '\(fixture.runID)'",
      at: databaseURL
    )

    await expectRollback(databaseURL: databaseURL, expectedVersion: 2)
    #expect(try JournalTestSupport.tableExists("runs_v2", at: databaseURL) == false)
  }

  private func expectRollback(databaseURL: URL, expectedVersion: Int) async {
    do {
      let journal = try await SQLiteAgentEventJournal.open(
        configuration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
      )
      try await journal.close()
      Issue.record("Migration admitted malformed legacy data.")
    } catch is SQLiteAgentEventJournalError {
      // Expected: semantic admission runs inside the migration transaction.
    } catch {
      Issue.record("Expected a journal error, received \(error).")
    }

    do {
      #expect(try JournalTestSupport.userVersion(at: databaseURL) == expectedVersion)
    } catch {
      Issue.record("Could not inspect the rolled-back schema version: \(error).")
    }
  }
}
