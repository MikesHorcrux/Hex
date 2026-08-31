import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("SQLite journal migrations")
struct SQLiteJournalMigrationTests {
  @Test
  func versionZeroDatabaseBuildsCurrentSchema() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)

    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    try await journal.close()

    #expect(try JournalTestSupport.userVersion(at: configuration.databaseURL) == 2)
    #expect(
      try JournalTestSupport.tableExists(
        "journal_checkpoints",
        at: configuration.databaseURL
      )
    )
  }

  @Test
  func genuineVersionOneFixtureMigratesWithoutLosingEvents() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let fixture = try JournalTestSupport.createVersionOneFixture(at: databaseURL)
    let configuration = SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)

    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let records = try await journal.records(for: fixture.runID, after: nil, limit: 10)
    #expect(records.map(\.event) == fixture.events)
    try await journal.close()

    #expect(try JournalTestSupport.userVersion(at: databaseURL) == 2)
    #expect(try JournalTestSupport.tableExists("journal_checkpoints", at: databaseURL))
  }

  @Test
  func failedVersionOneMigrationRollsBackAtomically() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    _ = try JournalTestSupport.createVersionOneFixture(at: databaseURL)
    try JournalTestSupport.execute(
      "CREATE INDEX event_records_run_kind_tool_call_idx ON runs (run_id)",
      at: databaseURL
    )

    do {
      _ = try await SQLiteAgentEventJournal.open(
        configuration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
      )
      Issue.record("Expected the conflicting v1 migration to fail.")
    } catch is SQLiteAgentEventJournalError {
      // Expected migration failure.
    }

    #expect(try JournalTestSupport.userVersion(at: databaseURL) == 1)
    #expect(try JournalTestSupport.tableExists("journal_checkpoints", at: databaseURL) == false)
  }

  @Test
  func futureSchemaFailsWithoutMutatingDatabaseContents() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    try JournalTestSupport.execute(
      """
      CREATE TABLE future_marker (value TEXT NOT NULL);
      INSERT INTO future_marker (value) VALUES ('untouched');
      PRAGMA user_version = 3;
      """,
      at: databaseURL
    )

    do {
      _ = try await SQLiteAgentEventJournal.open(
        configuration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
      )
      Issue.record("Expected future schema to fail.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(error == .futureSchemaVersion(found: 3, supported: 2))
    }

    #expect(try JournalTestSupport.userVersion(at: databaseURL) == 3)
    let marker = try JournalTestSupport.withConnection(at: databaseURL) { connection in
      try connection.scalarText("SELECT value FROM future_marker", maximumBytes: 64)
    }
    #expect(marker == "untouched")
  }

  @Test
  func currentSchemaWithWrongDeclaredTypeFailsClosed() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    try await journal.close()
    try JournalTestSupport.execute(
      """
      DROP INDEX event_records_run_kind_tool_call_idx;
      DROP TABLE event_records;
      CREATE TABLE event_records (
        event_id TEXT NOT NULL UNIQUE,
        run_id TEXT NOT NULL,
        sequence INTEGER NOT NULL,
        timestamp_us INTEGER NOT NULL,
        record_schema_version INTEGER NOT NULL,
        kind TEXT NOT NULL,
        tool_call_id TEXT,
        payload TEXT NOT NULL,
        PRIMARY KEY (run_id, sequence),
        FOREIGN KEY (run_id) REFERENCES runs(run_id) ON DELETE CASCADE
      );
      CREATE INDEX event_records_run_kind_tool_call_idx
      ON event_records (run_id, kind, tool_call_id);
      """,
      at: configuration.databaseURL
    )

    do {
      _ = try await SQLiteAgentEventJournal.open(configuration: configuration)
      Issue.record("Expected wrong declared type to fail.")
    } catch let error as SQLiteAgentEventJournalError {
      if case .corruptSchema = error {
        // Expected.
      } else {
        Issue.record("Expected corruptSchema, received \(error).")
      }
    }
  }

  @Test
  func currentSchemaMissingForeignKeyFailsClosed() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    try await journal.close()
    try JournalTestSupport.execute(
      """
      DROP INDEX event_records_run_kind_tool_call_idx;
      DROP TABLE event_records;
      CREATE TABLE event_records (
        event_id TEXT NOT NULL UNIQUE,
        run_id TEXT NOT NULL,
        sequence INTEGER NOT NULL,
        timestamp_us INTEGER NOT NULL,
        record_schema_version INTEGER NOT NULL,
        kind TEXT NOT NULL,
        tool_call_id TEXT,
        payload BLOB NOT NULL,
        PRIMARY KEY (run_id, sequence)
      );
      CREATE INDEX event_records_run_kind_tool_call_idx
      ON event_records (run_id, kind, tool_call_id);
      """,
      at: configuration.databaseURL
    )

    do {
      _ = try await SQLiteAgentEventJournal.open(configuration: configuration)
      Issue.record("Expected missing foreign key to fail.")
    } catch let error as SQLiteAgentEventJournalError {
      if case .corruptSchema = error {
        // Expected.
      } else {
        Issue.record("Expected corruptSchema, received \(error).")
      }
    }
  }
}
