import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("Persistence migration atomicity audit")
struct SQLiteJournalMigrationAtomicityAuditTests {
  @Test
  func failedOpenDoesNotCommitMigrationBeforePayloadAdmission() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let fixture = try JournalTestSupport.createVersionTwoFixture(at: databaseURL)
    try JournalTestSupport.execute(
      "UPDATE event_records SET payload = X'FF' WHERE run_id = '\(fixture.runID)' AND sequence = 1",
      at: databaseURL
    )

    do {
      let journal = try await SQLiteAgentEventJournal.open(
        configuration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
      )
      try await journal.close()
      Issue.record("Open admitted an undecodable historical payload.")
    } catch is SQLiteAgentEventJournalError {
      // Expected admission failure, but its schema rewrite must also roll back.
    }

    #expect(try JournalTestSupport.userVersion(at: databaseURL) == 2)
    #expect(try JournalTestSupport.tableExists("runs_v2", at: databaseURL) == false)
  }

  @Test
  func failedOpenDoesNotCommitMigrationBeforeCanonicalPayloadAdmission() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let fixture = try JournalTestSupport.createVersionTwoFixture(at: databaseURL)
    var noncanonicalPayload = Data([0x20])
    noncanonicalPayload.append(try AgentEventCodec.encode(event: .runStarted))
    try JournalTestSupport.withConnection(at: databaseURL) { connection in
      let statement = try connection.prepare(
        "UPDATE event_records SET payload = ? WHERE run_id = ? AND sequence = 1"
      )
      try statement.bind(noncanonicalPayload, at: 1)
      try statement.bind(fixture.runID.description, at: 2)
      _ = try statement.step()
    }

    await expectFailedMigrationRollback(databaseURL: databaseURL)
  }

  @Test
  func failedOpenDoesNotCommitMigrationBeforeLifecycleAdmission() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let fixture = try JournalTestSupport.createVersionTwoFixture(at: databaseURL)
    let call = ToolCall(
      id: ToolCallID(rawValue: "migration-pending-tool"),
      name: "noop",
      arguments: [:]
    )
    try JournalTestSupport.withConnection(at: databaseURL) { connection in
      try connection.withImmediateTransaction {
        let moveTerminal = try connection.prepare(
          "UPDATE event_records SET sequence = 3, timestamp_us = 3 WHERE run_id = ? AND sequence = 2"
        )
        try moveTerminal.bind(fixture.runID.description, at: 1)
        _ = try moveTerminal.step()

        let insertTool = try connection.prepare(
          """
          INSERT INTO event_records (
            event_id, run_id, sequence, timestamp_us, record_schema_version, kind, tool_call_id,
            payload
          ) VALUES (?, ?, 2, 2, 1, ?, ?, ?)
          """
        )
        try insertTool.bind(AgentEventID().description, at: 1)
        try insertTool.bind(fixture.runID.description, at: 2)
        try insertTool.bind(AgentEvent.toolStarted(call).journalKind, at: 3)
        try insertTool.bind(call.id.rawValue, at: 4)
        try insertTool.bind(AgentEventCodec.encode(event: .toolStarted(call)), at: 5)
        _ = try insertTool.step()

        let updateRun = try connection.prepare(
          "UPDATE runs SET next_sequence = 4, terminal_sequence = 3 WHERE run_id = ?"
        )
        try updateRun.bind(fixture.runID.description, at: 1)
        _ = try updateRun.step()
      }
    }

    await expectFailedMigrationRollback(databaseURL: databaseURL)
  }

  private func expectFailedMigrationRollback(databaseURL: URL) async {
    do {
      let journal = try await SQLiteAgentEventJournal.open(
        configuration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
      )
      try await journal.close()
      Issue.record("Open admitted invalid version-two history.")
    } catch is SQLiteAgentEventJournalError {
      // Expected: full admission remains inside the migration transaction.
    } catch {
      Issue.record("Expected a journal admission error, received \(error).")
    }

    do {
      #expect(try JournalTestSupport.userVersion(at: databaseURL) == 2)
      #expect(try JournalTestSupport.tableExists("runs_v2", at: databaseURL) == false)
    } catch {
      Issue.record("Could not inspect migration rollback state: \(error).")
    }
  }
}
