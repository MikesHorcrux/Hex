import Foundation
import Testing

@testable import HexPersistence

@Suite("Persistence structural corruption audit")
struct SQLiteJournalStructuralCorruptionAuditTests {
  @Test
  func openRejectsMetadataIndexWhoseRootPageAliasesAnotherBTree() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let initial = try await SQLiteAgentEventJournal.open(
      configuration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
    )
    try await initial.close()

    let mutator = Process()
    mutator.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    mutator.arguments = [
      databaseURL.path,
      """
      PRAGMA writable_schema = ON;
      UPDATE sqlite_schema
      SET rootpage = (SELECT rootpage FROM sqlite_schema WHERE name = 'runs')
      WHERE name = 'event_records_run_kind_tool_call_idx';
      PRAGMA writable_schema = OFF;
      """,
    ]
    try mutator.run()
    mutator.waitUntilExit()
    #expect(mutator.terminationReason == .exit)
    #expect(mutator.terminationStatus == 0)
    let integrityResult = try JournalTestSupport.withConnection(at: databaseURL) { connection in
      try connection.scalarText("PRAGMA integrity_check", maximumBytes: 1_024)
    }
    #expect(integrityResult != "ok")

    do {
      let reopened = try await SQLiteAgentEventJournal.open(
        configuration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
      )
      try await reopened.close()
      Issue.record("Open admitted a structurally invalid metadata-index b-tree root.")
    } catch is SQLiteAgentEventJournalError {
      // Expected bounded structural validation to fail closed.
    }
  }
}
