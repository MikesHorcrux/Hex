import Foundation
import Testing

@testable import HexPersistence

@Suite("SQLite journal schema hardening")
struct SQLiteJournalSchemaHardeningTests {
  @Test(
    arguments: [
      """
      CREATE TRIGGER discard_event AFTER INSERT ON event_records
      BEGIN
        DELETE FROM event_records WHERE event_id = NEW.event_id;
      END
      """,
      """
      CREATE TRIGGER copy_event AFTER INSERT ON event_records
      BEGIN
        UPDATE runs SET updated_at_us = updated_at_us WHERE run_id = NEW.run_id;
      END
      """,
      """
      CREATE TRIGGER mutate_run AFTER UPDATE ON runs
      BEGIN
        SELECT 1;
      END
      """,
      "CREATE VIEW event_view AS SELECT * FROM event_records",
      "CREATE TABLE unexpected_table (value TEXT)",
      "CREATE INDEX unexpected_index ON runs (updated_at_us)",
    ]
  )
  func rejectsUnexpectedSchemaObjects(_ hostileSQL: String) async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    try await journal.close()
    try JournalTestSupport.execute(hostileSQL, at: configuration.databaseURL)

    do {
      _ = try await SQLiteAgentEventJournal.open(configuration: configuration)
      Issue.record("Expected an unexpected schema object to fail closed.")
    } catch let error as SQLiteAgentEventJournalError {
      guard case .corruptSchema = error else {
        Issue.record("Expected corruptSchema, received \(error).")
        return
      }
    }
  }

  @Test
  func rejectsGeneratedColumnHiddenFromTableInfo() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    try await journal.close()
    try JournalTestSupport.execute(
      """
      ALTER TABLE runs ADD COLUMN forged_sequence INTEGER
      GENERATED ALWAYS AS (next_sequence + 1) VIRTUAL
      """,
      at: configuration.databaseURL
    )

    do {
      _ = try await SQLiteAgentEventJournal.open(configuration: configuration)
      Issue.record("Expected a hidden generated column to fail closed.")
    } catch let error as SQLiteAgentEventJournalError {
      guard case .corruptSchema = error else {
        Issue.record("Expected corruptSchema, received \(error).")
        return
      }
    }
  }

  @Test
  func rejectsTriggerAddedAfterOpenBeforeSuccessfulAppend() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    try JournalTestSupport.execute(
      """
      CREATE TRIGGER discard_event AFTER INSERT ON event_records
      BEGIN
        DELETE FROM event_records WHERE event_id = NEW.event_id;
      END
      """,
      at: configuration.databaseURL
    )

    do {
      _ = try await journal.append(.runStarted, to: .init())
      Issue.record("Expected a post-open trigger to reject the append before mutation.")
    } catch let error as SQLiteAgentEventJournalError {
      guard case .corruptSchema = error else {
        Issue.record("Expected corruptSchema, received \(error).")
        return
      }
    }
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM event_records",
        at: configuration.databaseURL
      ) == 0
    )
    try await journal.close()
  }
}
