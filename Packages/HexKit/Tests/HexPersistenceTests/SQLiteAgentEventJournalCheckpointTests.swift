import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("SQLite agent-event journal checkpoints")
struct SQLiteAgentEventJournalCheckpointTests {
  @Test
  func checkpointsAreDurableImmutableIdempotentAndOrdered() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    let firstSnapshot = JSONValue.object([
      "messages": .integer(0),
      "state": .string("started"),
    ])

    let first = try await journal.writeCheckpoint(
      for: runID,
      through: 1,
      snapshot: firstSnapshot
    )
    let identicalRetry = try await journal.writeCheckpoint(
      for: runID,
      through: 1,
      snapshot: firstSnapshot
    )
    #expect(identicalRetry == first)

    do {
      _ = try await journal.writeCheckpoint(
        for: runID,
        through: 1,
        snapshot: .object(["state": .string("replacement")])
      )
      Issue.record("Expected immutable checkpoint conflict.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(error == .checkpointConflict(runID: runID, sequence: 1))
    }

    do {
      _ = try await journal.writeCheckpoint(for: runID, through: 2, snapshot: .null)
      Issue.record("Expected checkpoint for a missing event to fail.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(error == .checkpointSequenceMissing(runID: runID, sequence: 2))
    }

    _ = try await journal.append(
      .messageAppended(Message(role: .user, content: [.text("hello")])),
      to: runID
    )
    let second = try await journal.writeCheckpoint(
      for: runID,
      through: 2,
      snapshot: .object(["messages": .integer(1)])
    )
    #expect(try await journal.latestCheckpoint(for: runID) == second)
    try await journal.close()

    let reopened = try await SQLiteAgentEventJournal.open(configuration: configuration)
    #expect(try await reopened.latestCheckpoint(for: runID) == second)
    try await reopened.close()
  }

  @Test
  func oversizedStoredCheckpointFailsBeforeDecode() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = SQLiteAgentEventJournalConfiguration(
      databaseURL: JournalTestSupport.databaseURL(in: directory),
      maximumPayloadBytes: 64
    )
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    _ = try await journal.append(.runCompleted, to: runID)
    _ = try await journal.writeCheckpoint(
      for: runID,
      through: 2,
      snapshot: .object(["state": .string("done")])
    )
    try await journal.close()
    try JournalTestSupport.execute(
      "UPDATE journal_checkpoints SET snapshot = zeroblob(65) WHERE run_id = '\(runID)'",
      at: configuration.databaseURL
    )

    do {
      let reopened = try await SQLiteAgentEventJournal.open(configuration: configuration)
      try await reopened.close()
      Issue.record("Expected oversized checkpoint to fail during open admission.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(error == .payloadTooLarge(actual: 65, maximum: 64))
    }
  }

  @Test
  func checkpointReferencingDeletedEventFailsClosed() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    _ = try await journal.append(.runCompleted, to: runID)
    _ = try await journal.writeCheckpoint(for: runID, through: 2, snapshot: .null)
    try await journal.close()
    try JournalTestSupport.execute(
      "DELETE FROM event_records WHERE run_id = '\(runID)' AND sequence = 2",
      at: configuration.databaseURL
    )

    do {
      let reopened = try await SQLiteAgentEventJournal.open(configuration: configuration)
      try await reopened.close()
      Issue.record("Expected dangling checkpoint to fail during open admission.")
    } catch let error as SQLiteAgentEventJournalError {
      if case .corruptRecord = error {
        // Expected.
      } else {
        Issue.record("Expected corruptRecord, received \(error).")
      }
    }
  }

  @Test
  func checkpointReadRejectsMissingRunMetadataInsideItsSnapshot() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    _ = try await journal.writeCheckpoint(for: runID, through: 1, snapshot: .null)
    try JournalTestSupport.execute(
      "DELETE FROM runs WHERE run_id = '\(runID)'",
      at: configuration.databaseURL
    )

    await expectCorruptCheckpoint(journal: journal, runID: runID)
    try await journal.close()
  }

  @Test
  func checkpointReadRejectsOrphanEventsEvenWithoutCheckpoint() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    try JournalTestSupport.execute(
      "DELETE FROM runs WHERE run_id = '\(runID)'",
      at: configuration.databaseURL
    )

    await expectCorruptCheckpoint(journal: journal, runID: runID)
    try await journal.close()
  }

  private func expectCorruptCheckpoint(
    journal: SQLiteAgentEventJournal,
    runID: AgentRunID
  ) async {
    do {
      _ = try await journal.latestCheckpoint(for: runID)
      Issue.record("Expected inconsistent checkpoint state to fail closed.")
    } catch let error as SQLiteAgentEventJournalError {
      switch error {
      case .corruptRecord, .corruptSchema:
        break
      default:
        Issue.record("Expected durable corruption, received \(error).")
      }
    } catch {
      Issue.record("Expected a journal error, received \(error).")
    }
  }
}
