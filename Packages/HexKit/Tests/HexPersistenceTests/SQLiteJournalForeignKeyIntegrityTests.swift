import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("SQLite journal foreign-key integrity")
struct SQLiteJournalForeignKeyIntegrityTests {
  @Test
  func appendRejectsPostOpenOrphanBeforeMutation() async throws {
    let fixture = try await makeOrphanFixture()
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    let newRunID = AgentRunID()

    await expectCorruptSchema {
      _ = try await fixture.journal.append(.runStarted, to: newRunID)
    }
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM runs WHERE run_id = '\(newRunID)'",
        at: fixture.configuration.databaseURL
      ) == 0
    )
    try await fixture.journal.close()
  }

  @Test
  func checkpointRejectsPostOpenOrphanBeforeMutation() async throws {
    let fixture = try await makeOrphanFixture(includeValidRun: true)
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    guard let validRunID = fixture.validRunID else {
      Issue.record("Expected a valid-run fixture.")
      return
    }

    await expectCorruptSchema {
      _ = try await fixture.journal.writeCheckpoint(
        for: validRunID,
        through: 1,
        snapshot: .object(["state": .string("must-not-commit")])
      )
    }
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM journal_checkpoints WHERE run_id = '\(validRunID)'",
        at: fixture.configuration.databaseURL
      ) == 0
    )
    try await fixture.journal.close()
  }

  @Test
  func recoveryRejectsPostOpenOrphanBeforeMutation() async throws {
    let fixture = try await makeOrphanFixture(includeValidRun: true)
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    guard let validRunID = fixture.validRunID else {
      Issue.record("Expected a valid-run fixture.")
      return
    }

    await expectCorruptSchema {
      _ = try await fixture.journal.recoverInterruptedRuns()
    }
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM event_records WHERE run_id = '\(validRunID)'",
        at: fixture.configuration.databaseURL
      ) == 1
    )
    try await fixture.journal.close()
  }

  private func makeOrphanFixture(
    includeValidRun: Bool = false
  ) async throws -> (
    directory: URL,
    configuration: SQLiteAgentEventJournalConfiguration,
    journal: SQLiteAgentEventJournal,
    validRunID: AgentRunID?
  ) {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let validRunID = includeValidRun ? AgentRunID() : nil
    if let validRunID {
      _ = try await journal.append(.runStarted, to: validRunID)
    }
    let orphanRunID = AgentRunID()
    _ = try await journal.append(.runStarted, to: orphanRunID)
    try JournalTestSupport.execute(
      "DELETE FROM runs WHERE run_id = '\(orphanRunID)'",
      at: configuration.databaseURL
    )
    return (directory, configuration, journal, validRunID)
  }

  private func expectCorruptSchema(
    _ operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      Issue.record("Expected foreign-key corruption to fail closed.")
    } catch let error as SQLiteAgentEventJournalError {
      guard case .corruptSchema = error else {
        Issue.record("Expected corruptSchema, received \(error).")
        return
      }
    } catch {
      Issue.record("Expected a journal error, received \(error).")
    }
  }
}
