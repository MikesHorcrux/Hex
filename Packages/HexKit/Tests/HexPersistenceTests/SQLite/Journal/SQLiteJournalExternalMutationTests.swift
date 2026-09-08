import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("SQLite journal external mutation boundary")
struct SQLiteJournalExternalMutationTests {
  @Test
  func appendRejectsCorruptionInAnUnrelatedRunWithoutWriting() async throws {
    let fixture = try await makeFixture()
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    try corruptUnrelatedRun(fixture)

    await #expect(throws: SQLiteAgentEventJournalError.self) {
      try await fixture.journal.append(
        .inferenceEvent(.textDelta("must not commit")),
        to: fixture.activeRunID
      )
    }
    let activeRecordCount = try JournalTestSupport.scalarInt64(
      "SELECT COUNT(*) FROM event_records WHERE run_id = '\(fixture.activeRunID)'",
      at: fixture.configuration.databaseURL
    )
    #expect(activeRecordCount == 1)
    try await fixture.journal.close()
  }

  @Test
  func readRejectsCorruptionInAnUnrelatedRun() async throws {
    let fixture = try await makeFixture()
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    try corruptUnrelatedRun(fixture)

    await #expect(throws: SQLiteAgentEventJournalError.self) {
      try await fixture.journal.records(for: fixture.activeRunID, after: nil, limit: 1)
    }
    try await fixture.journal.close()
  }

  @Test
  func checkpointReadRejectsCorruptionInAnUnrelatedRun() async throws {
    let fixture = try await makeFixture()
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    _ = try await fixture.journal.writeCheckpoint(
      for: fixture.activeRunID,
      through: 1,
      snapshot: .null
    )
    try corruptUnrelatedRun(fixture)

    await #expect(throws: SQLiteAgentEventJournalError.self) {
      try await fixture.journal.latestCheckpoint(for: fixture.activeRunID)
    }
    try await fixture.journal.close()
  }

  @Test
  func ownCommitsAndExternalReadOnlyConnectionPreserveBaseline() async throws {
    let fixture = try await makeFixture()
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    _ = try JournalTestSupport.scalarInt64(
      "SELECT COUNT(*) FROM event_records",
      at: fixture.configuration.databaseURL
    )

    _ = try await fixture.journal.append(.runCompleted, to: fixture.activeRunID)
    let page = try await fixture.journal.records(
      for: fixture.activeRunID,
      after: nil,
      limit: 2
    )
    #expect(page.map(\.event) == [.runStarted, .runCompleted])
    try await fixture.journal.close()
  }

  @Test
  func validExternalWriteDoesNotReplaceTheOwnedBaseline() async throws {
    let fixture = try await makeFixture()
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    try JournalTestSupport.execute(
      "UPDATE runs SET updated_at_us = updated_at_us + 1 WHERE run_id = '\(fixture.unrelatedRunID)'",
      at: fixture.configuration.databaseURL
    )

    for _ in 0..<2 {
      await #expect(
        throws: SQLiteAgentEventJournalError.corruptRecord(
          "The journal changed through another SQLite connection while it was open."
        )
      ) {
        try await fixture.journal.append(.runCompleted, to: fixture.activeRunID)
      }
    }
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM event_records WHERE run_id = '\(fixture.activeRunID)'",
        at: fixture.configuration.databaseURL
      ) == 1
    )
    try await fixture.journal.close()
  }

  private func makeFixture() async throws -> Fixture {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let unrelatedRunID = AgentRunID()
    _ = try await journal.append(.runStarted, to: unrelatedRunID)
    _ = try await journal.append(.runCompleted, to: unrelatedRunID)
    let activeRunID = AgentRunID()
    _ = try await journal.append(.runStarted, to: activeRunID)
    return Fixture(
      directory: directory,
      configuration: configuration,
      journal: journal,
      unrelatedRunID: unrelatedRunID,
      activeRunID: activeRunID
    )
  }

  private func corruptUnrelatedRun(_ fixture: Fixture) throws {
    try JournalTestSupport.execute(
      """
      UPDATE event_records SET payload = X'FF'
      WHERE run_id = '\(fixture.unrelatedRunID)' AND sequence = 1
      """,
      at: fixture.configuration.databaseURL
    )
  }

  private struct Fixture {
    let directory: URL
    let configuration: SQLiteAgentEventJournalConfiguration
    let journal: SQLiteAgentEventJournal
    let unrelatedRunID: AgentRunID
    let activeRunID: AgentRunID
  }
}
