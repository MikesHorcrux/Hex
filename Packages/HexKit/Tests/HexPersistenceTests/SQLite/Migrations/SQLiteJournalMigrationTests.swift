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

    #expect(try JournalTestSupport.userVersion(at: configuration.databaseURL) == 5)
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

    #expect(try JournalTestSupport.userVersion(at: databaseURL) == 5)
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
      PRAGMA user_version = 6;
      """,
      at: databaseURL
    )

    do {
      _ = try await SQLiteAgentEventJournal.open(
        configuration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
      )
      Issue.record("Expected future schema to fail.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(error == .futureSchemaVersion(found: 6, supported: 5))
    }

    #expect(try JournalTestSupport.userVersion(at: databaseURL) == 6)
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

  @Test
  func versionTwoMigrationCanonicalizesCollisionFreeUUIDText() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let fixture = try JournalTestSupport.createVersionTwoFixture(at: databaseURL)
    try JournalTestSupport.execute(
      """
      UPDATE event_records
      SET event_id = lower(event_id), run_id = lower(run_id);
      UPDATE runs SET run_id = lower(run_id);
      """,
      at: databaseURL
    )

    let journal = try await SQLiteAgentEventJournal.open(
      configuration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
    )
    let records = try await journal.records(for: fixture.runID, after: nil, limit: 10)
    #expect(records.map(\.event) == fixture.events)
    try await journal.close()

    #expect(try JournalTestSupport.userVersion(at: databaseURL) == 5)
    #expect(
      try JournalTestSupport.scalarInt64(
        """
        SELECT
          (SELECT COUNT(*) FROM runs WHERE run_id != upper(run_id)) +
          (SELECT COUNT(*) FROM event_records
           WHERE run_id != upper(run_id) OR event_id != upper(event_id))
        """,
        at: databaseURL
      ) == 0
    )
  }

  @Test
  func versionTwoMigrationRejectsLogicalUUIDCollisionAtomically() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let canonicalRunID = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
    try JournalTestSupport.withConnection(at: databaseURL) { connection in
      try connection.execute(
        """
        CREATE TABLE runs (
          run_id TEXT PRIMARY KEY NOT NULL,
          next_sequence INTEGER NOT NULL,
          terminal_sequence INTEGER,
          created_at_us INTEGER NOT NULL,
          updated_at_us INTEGER NOT NULL
        );
        CREATE TABLE event_records (
          event_id TEXT NOT NULL UNIQUE,
          run_id TEXT NOT NULL,
          sequence INTEGER NOT NULL,
          timestamp_us INTEGER NOT NULL,
          record_schema_version INTEGER NOT NULL,
          kind TEXT NOT NULL,
          tool_call_id TEXT,
          payload BLOB NOT NULL,
          PRIMARY KEY (run_id, sequence),
          FOREIGN KEY (run_id) REFERENCES runs(run_id) ON DELETE CASCADE
        );
        CREATE TABLE journal_checkpoints (
          run_id TEXT NOT NULL,
          through_sequence INTEGER NOT NULL,
          created_at_us INTEGER NOT NULL,
          checkpoint_schema_version INTEGER NOT NULL,
          snapshot BLOB NOT NULL,
          PRIMARY KEY (run_id, through_sequence),
          FOREIGN KEY (run_id) REFERENCES runs(run_id) ON DELETE CASCADE
        );
        CREATE INDEX event_records_run_kind_tool_call_idx
        ON event_records (run_id, kind, tool_call_id);
        INSERT INTO runs VALUES ('\(canonicalRunID)', 1, NULL, 1, 1);
        INSERT INTO runs VALUES ('\(canonicalRunID.lowercased())', 1, NULL, 1, 1);
        PRAGMA user_version = 2;
        """
      )
    }

    do {
      _ = try await SQLiteAgentEventJournal.open(
        configuration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
      )
      Issue.record("Expected logical UUID collision to abort migration.")
    } catch let error as SQLiteAgentEventJournalError {
      guard case .corruptSchema(let reason) = error, reason.contains("UUID collision") else {
        Issue.record("Expected UUID-collision corruptSchema, received \(error).")
        return
      }
    }

    #expect(try JournalTestSupport.userVersion(at: databaseURL) == 2)
    #expect(try JournalTestSupport.scalarInt64("SELECT COUNT(*) FROM runs", at: databaseURL) == 2)
  }

  @Test
  func versionTwoMigrationRejectsLogicalEventIDCollisionAtomically() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let fixture = try JournalTestSupport.createVersionTwoFixture(at: databaseURL)
    let firstEventID = try JournalTestSupport.withConnection(at: databaseURL) { connection in
      try connection.scalarText(
        "SELECT event_id FROM event_records WHERE run_id = '\(fixture.runID)' AND sequence = 1",
        maximumBytes: 64
      )
    }
    try JournalTestSupport.execute(
      "UPDATE event_records SET event_id = '\(firstEventID.lowercased())' WHERE sequence = 2",
      at: databaseURL
    )

    do {
      _ = try await SQLiteAgentEventJournal.open(
        configuration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
      )
      Issue.record("Expected logical event UUID collision to abort migration.")
    } catch let error as SQLiteAgentEventJournalError {
      guard case .corruptSchema(let reason) = error, reason.contains("UUID collision") else {
        Issue.record("Expected UUID-collision corruptSchema, received \(error).")
        return
      }
    }

    #expect(try JournalTestSupport.userVersion(at: databaseURL) == 2)
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM event_records",
        at: databaseURL
      ) == 2
    )
  }
}
