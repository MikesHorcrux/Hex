import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("Persistence post-mutation bound audit")
struct SQLiteJournalPostMutationBoundsAuditTests {
  @Test
  func appendCannotCreateMoreRunsThanTheJournalCanSubsequentlyValidate() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = SQLiteAgentEventJournalConfiguration(
      databaseURL: JournalTestSupport.databaseURL(in: directory),
      maximumRecoveryRunCount: 1
    )
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let firstRunID = AgentRunID()
    _ = try await journal.append(.runStarted, to: firstRunID)
    _ = try await journal.append(.runCompleted, to: firstRunID)

    do {
      _ = try await journal.append(.runStarted, to: AgentRunID())
      Issue.record("append exceeded the configured whole-journal run bound.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(error == .integrityRunLimitExceeded(maximum: 1))
    }

    let records = try await journal.records(for: firstRunID, after: nil, limit: 10)
    #expect(records.count == 2)
    try await journal.close()
  }

  @Test
  func appendCannotCreateMoreRecordsThanTheJournalCanSubsequentlyValidate() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = SQLiteAgentEventJournalConfiguration(
      databaseURL: JournalTestSupport.databaseURL(in: directory),
      maximumRecoveryRecordCount: 2
    )
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    _ = try await journal.append(
      .messageAppended(Message(role: .user, content: [.text("at-capacity")])),
      to: runID
    )

    do {
      _ = try await journal.append(.runCompleted, to: runID)
      Issue.record("append exceeded the configured whole-journal record bound.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(error == .integrityRecordLimitExceeded(maximum: 2))
    }

    let records = try await journal.records(for: runID, after: nil, limit: 10)
    #expect(records.count == 2)
    try await journal.close()
  }

  @Test
  func checkpointCannotCreateMoreRecordsThanTheJournalCanSubsequentlyValidate() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = SQLiteAgentEventJournalConfiguration(
      databaseURL: JournalTestSupport.databaseURL(in: directory),
      maximumRecoveryRecordCount: 2
    )
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    _ = try await journal.append(.runCompleted, to: runID)

    do {
      _ = try await journal.writeCheckpoint(for: runID, through: 2, snapshot: .null)
      Issue.record("writeCheckpoint exceeded the configured whole-journal record bound.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(error == .integrityRecordLimitExceeded(maximum: 2))
    }

    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM journal_checkpoints WHERE run_id = '\(runID)'",
        at: configuration.databaseURL
      ) == 0
    )
    let records = try await journal.records(for: runID, after: nil, limit: 10)
    #expect(records.count == 2)
    try await journal.close()
  }

  @Test
  func checkpointCannotCreateMoreBytesThanTheJournalCanSubsequentlyValidate() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let event = AgentEvent.runStarted
    let bytesBeforeCheckpoint =
      36 + 36 + 36 + event.journalKind.utf8.count
      + (try AgentEventCodec.encode(event: event)).count
    let configuration = SQLiteAgentEventJournalConfiguration(
      databaseURL: JournalTestSupport.databaseURL(in: directory),
      maximumRecoveryBytes: bytesBeforeCheckpoint
    )
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(event, to: runID)

    do {
      _ = try await journal.writeCheckpoint(for: runID, through: 1, snapshot: .null)
      Issue.record("writeCheckpoint exceeded the configured whole-journal byte bound.")
    } catch let error as SQLiteAgentEventJournalError {
      guard case .integrityByteLimitExceeded(_, let maximum) = error else {
        Issue.record("Expected integrityByteLimitExceeded, received \(error).")
        try await journal.close()
        return
      }
      #expect(maximum == bytesBeforeCheckpoint)
    }

    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM journal_checkpoints WHERE run_id = '\(runID)'",
        at: configuration.databaseURL
      ) == 0
    )
    let records = try await journal.records(for: runID, after: nil, limit: 10)
    #expect(records.count == 1)
    try await journal.close()
  }

  @Test
  func appendCannotCreateMoreBytesThanTheJournalCanSubsequentlyValidate() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = SQLiteAgentEventJournalConfiguration(
      databaseURL: JournalTestSupport.databaseURL(in: directory),
      maximumRecoveryBytes: 36
    )
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()

    do {
      _ = try await journal.append(.runStarted, to: runID)
      Issue.record("append exceeded the configured whole-journal byte bound.")
    } catch let error as SQLiteAgentEventJournalError {
      guard case .integrityByteLimitExceeded(_, let maximum) = error else {
        Issue.record("Expected integrityByteLimitExceeded, received \(error).")
        try await journal.close()
        return
      }
      #expect(maximum == 36)
    }

    let records = try await journal.records(for: runID, after: nil, limit: 10)
    #expect(records.isEmpty)
    try await journal.close()
  }
}
