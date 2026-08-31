import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("SQLite journal read integrity")
struct SQLiteJournalReadIntegrityTests {
  @Test
  func rejectsSequenceGapOutsideRequestedPage() async throws {
    let fixture = try await makeRun(messageCount: 2)
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    try JournalTestSupport.execute(
      "DELETE FROM event_records WHERE run_id = '\(fixture.runID)' AND sequence = 2",
      at: fixture.configuration.databaseURL
    )

    await expectCorruptRead(journal: fixture.journal, runID: fixture.runID, after: 2)
    try await fixture.journal.close()
  }

  @Test
  func rejectsMissingTerminalRecord() async throws {
    let fixture = try await makeRun(messageCount: 0)
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    try JournalTestSupport.execute(
      "DELETE FROM event_records WHERE run_id = '\(fixture.runID)' AND sequence = 2",
      at: fixture.configuration.databaseURL
    )

    await expectCorruptRead(journal: fixture.journal, runID: fixture.runID)
    try await fixture.journal.close()
  }

  @Test
  func rejectsTerminalMetadataWithoutAnyRecords() async throws {
    let fixture = try await makeRun(messageCount: 0)
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    try JournalTestSupport.execute(
      "DELETE FROM event_records WHERE run_id = '\(fixture.runID)'",
      at: fixture.configuration.databaseURL
    )

    await expectCorruptRead(journal: fixture.journal, runID: fixture.runID)
    try await fixture.journal.close()
  }

  @Test
  func rejectsTerminalRecordWithMissingMetadata() async throws {
    let fixture = try await makeRun(messageCount: 0)
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    try JournalTestSupport.execute(
      "UPDATE runs SET terminal_sequence = NULL WHERE run_id = '\(fixture.runID)'",
      at: fixture.configuration.databaseURL
    )

    await expectCorruptRead(journal: fixture.journal, runID: fixture.runID)
    try await fixture.journal.close()
  }

  @Test
  func rejectsTerminalMetadataPointingAtNonterminalRecord() async throws {
    let fixture = try await makeRun(messageCount: 1)
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    try JournalTestSupport.execute(
      "UPDATE runs SET terminal_sequence = 2 WHERE run_id = '\(fixture.runID)'",
      at: fixture.configuration.databaseURL
    )

    await expectCorruptRead(journal: fixture.journal, runID: fixture.runID)
    try await fixture.journal.close()
  }

  @Test
  func rejectsNextSequenceMismatch() async throws {
    let fixture = try await makeRun(messageCount: 1)
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    try JournalTestSupport.execute(
      "UPDATE runs SET next_sequence = 99 WHERE run_id = '\(fixture.runID)'",
      at: fixture.configuration.databaseURL
    )

    await expectCorruptRead(journal: fixture.journal, runID: fixture.runID)
    try await fixture.journal.close()
  }

  private func makeRun(
    messageCount: Int
  ) async throws -> (
    directory: URL,
    configuration: SQLiteAgentEventJournalConfiguration,
    journal: SQLiteAgentEventJournal,
    runID: AgentRunID
  ) {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    for index in 0..<messageCount {
      _ = try await journal.append(
        .messageAppended(Message(role: .user, content: [.text("message-\(index)")])),
        to: runID
      )
    }
    _ = try await journal.append(.runCompleted, to: runID)
    return (directory, configuration, journal, runID)
  }

  private func expectCorruptRead(
    journal: SQLiteAgentEventJournal,
    runID: AgentRunID,
    after sequence: UInt64? = nil
  ) async {
    do {
      _ = try await journal.records(for: runID, after: sequence, limit: 10)
      Issue.record("Expected structurally corrupt run data to fail closed.")
    } catch let error as SQLiteAgentEventJournalError {
      guard case .corruptRecord = error else {
        Issue.record("Expected corruptRecord, received \(error).")
        return
      }
    } catch {
      Issue.record("Expected a journal error, received \(error).")
    }
  }
}
