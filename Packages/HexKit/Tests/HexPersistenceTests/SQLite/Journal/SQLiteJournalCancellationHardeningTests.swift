import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("SQLite journal cancellation hardening")
struct SQLiteJournalCancellationHardeningTests {
  @Test
  func cancelledAppendWaitingForBeginDoesNotMutate() async throws {
    let fixture = try await makeOpenRun()
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    let blocker = try SQLiteWriteBlocker(databaseURL: fixture.configuration.databaseURL)
    try await blocker.begin()
    let appendTask = Task {
      try await fixture.journal.append(
        .messageAppended(Message(role: .user, content: [.text("must-not-commit")])),
        to: fixture.runID
      )
    }
    try await Task.sleep(for: .milliseconds(100))
    appendTask.cancel()
    try await blocker.release()

    do {
      _ = try await appendTask.value
      Issue.record("Expected the blocked append to observe cancellation.")
    } catch is CancellationError {
      // Cancellation must be checked after BEGIN succeeds and before mutation.
    }
    let records = try await fixture.journal.records(for: fixture.runID, after: nil, limit: 10)
    #expect(records.map(\.sequence) == [1])
    try await fixture.journal.close()
  }

  @Test
  func cancelledCheckpointWaitingForBeginDoesNotMutate() async throws {
    let fixture = try await makeOpenRun()
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    let blocker = try SQLiteWriteBlocker(databaseURL: fixture.configuration.databaseURL)
    try await blocker.begin()
    let checkpointTask = Task {
      try await fixture.journal.writeCheckpoint(
        for: fixture.runID,
        through: 1,
        snapshot: .object(["state": .string("must-not-commit")])
      )
    }
    try await Task.sleep(for: .milliseconds(100))
    checkpointTask.cancel()
    try await blocker.release()

    do {
      _ = try await checkpointTask.value
      Issue.record("Expected the blocked checkpoint to observe cancellation.")
    } catch is CancellationError {
      // Cancellation must be checked after BEGIN succeeds and before mutation.
    }
    #expect(try await fixture.journal.latestCheckpoint(for: fixture.runID) == nil)
    try await fixture.journal.close()
  }

  private func makeOpenRun() async throws -> (
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
    return (directory, configuration, journal, runID)
  }
}
