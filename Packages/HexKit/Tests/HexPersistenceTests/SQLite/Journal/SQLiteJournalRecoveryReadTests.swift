import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("SQLite indexed recovery reads")
struct SQLiteJournalRecoveryReadTests {
  @Test
  func snapshotsAndBoundedPagesPreserveIdentityAcrossReopen() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    var records: [AgentEventRecord] = []
    for event in [
      AgentEvent.runStarted, .messageAppended(Message(role: .user, content: [.text("hello")])),
      .runCompleted,
    ] {
      records.append(try await journal.append(event, to: runID))
    }
    let snapshot = try #require(try await journal.runSnapshot(for: runID))
    #expect(snapshot.runID == runID)
    #expect(snapshot.firstEventID == records.first?.id)
    #expect(snapshot.latestSequence == 3)
    #expect(snapshot.terminalRecord == records.last)
    #expect(try await journal.runSnapshot(for: AgentRunID()) == nil)
    let first = try await journal.recoveryRecords(
      for: runID, after: 0, through: 3, limit: 2, maximumBytes: 32_768)
    let second = try await journal.recoveryRecords(
      for: runID, after: 2, through: 3, limit: 2, maximumBytes: 32_768)
    #expect(first + second == records)
    #expect(
      try await journal.recoveryRecords(
        for: runID, after: 3, through: 3, limit: 2, maximumBytes: 32_768
      ).isEmpty)
    try await journal.close()
    let reopened = try await SQLiteAgentEventJournal.open(configuration: configuration)
    #expect(try await reopened.runSnapshot(for: runID) == snapshot)
    #expect(
      try await reopened.recoveryRecords(
        for: runID, after: 0, through: 3, limit: 3, maximumBytes: 32_768) == records)
    try await reopened.close()
  }

  @Test
  func fixedHighWaterDoesNotIncludeLaterAppendsAndInvalidRequestsFailClosed() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: JournalTestSupport.configuration(in: directory))
    let runID = AgentRunID()
    let first = try await journal.append(.runStarted, to: runID)
    let captured = try #require(try await journal.runSnapshot(for: runID))
    #expect(captured.terminalRecord == nil)
    _ = try await journal.append(.runCancelled, to: runID)
    #expect(
      try await journal.recoveryRecords(
        for: runID, after: 0, through: captured.latestSequence, limit: 8, maximumBytes: 32_768) == [
          first
        ])
    for (after, through, limit, bytes) in [
      (UInt64(0), UInt64(3), 2, 32_768), (2, 1, 2, 32_768), (0, 2, 0, 32_768), (0, 2, 2, 0),
      (0, 2, 2, 1),
    ] {
      do {
        _ = try await journal.recoveryRecords(
          for: runID, after: after, through: through, limit: limit, maximumBytes: bytes)
        Issue.record("Expected invalid recovery bounds to fail.")
      } catch {}
    }
    try await journal.close()
  }

  @Test
  func externalMutationInvalidatesRecoveryReadsInsteadOfAdoptingAnotherHistory() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    _ = try await journal.append(.runCompleted, to: runID)
    try JournalTestSupport.execute(
      "UPDATE runs SET next_sequence = 99", at: configuration.databaseURL)
    do {
      _ = try await journal.runSnapshot(for: runID)
      Issue.record("Expected externally changed metadata to fail.")
    } catch {}
    do {
      _ = try await journal.recoveryRecords(
        for: runID, after: 0, through: 2, limit: 2, maximumBytes: 32_768)
      Issue.record("Expected externally changed history to fail.")
    } catch {}
    try await journal.close()
  }
}
