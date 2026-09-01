import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("Independent persistence bound audit")
struct SQLiteJournalIndependentBoundAuditTests {
  @Test
  func terminalJournalAtExactRunRecordAndByteCapsReopens() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let started = AgentEvent.runStarted
    let terminal = SQLiteInterruptedRunTerminal.event
    let exactBytes =
      36
      + 36 + 36 + started.journalKind.utf8.count
      + (try AgentEventCodec.encode(event: started)).count
      + 36 + 36 + terminal.journalKind.utf8.count
      + (try AgentEventCodec.encode(event: terminal)).count
    let configuration = SQLiteAgentEventJournalConfiguration(
      databaseURL: JournalTestSupport.databaseURL(in: directory),
      maximumRecoveryRunCount: 1,
      maximumRecoveryRecordCount: 2,
      maximumRecoveryBytes: exactBytes
    )
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(started, to: runID)
    _ = try await journal.append(terminal, to: runID)
    try await journal.close()

    let reopened = try await SQLiteAgentEventJournal.open(configuration: configuration)
    #expect(await reopened.recoveredRuns.isEmpty)
    #expect(try await reopened.records(for: runID, after: nil, limit: 2).count == 2)
    try await reopened.close()
  }

  @Test
  func checkpointAtExactRecordAndByteCapsReopens() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let started = AgentEvent.runStarted
    let terminal = SQLiteInterruptedRunTerminal.event
    let checkpointPayload = try AgentEventCodec.encode(snapshot: .null)
    let exactBytes =
      36
      + 36 + 36 + started.journalKind.utf8.count
      + (try AgentEventCodec.encode(event: started)).count
      + 36 + 36 + terminal.journalKind.utf8.count
      + (try AgentEventCodec.encode(event: terminal)).count
      + 36 + checkpointPayload.count
    let configuration = SQLiteAgentEventJournalConfiguration(
      databaseURL: JournalTestSupport.databaseURL(in: directory),
      maximumRecoveryRunCount: 1,
      maximumRecoveryRecordCount: 3,
      maximumRecoveryBytes: exactBytes
    )
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(started, to: runID)
    _ = try await journal.append(terminal, to: runID)
    _ = try await journal.writeCheckpoint(for: runID, through: 2, snapshot: .null)
    try await journal.close()

    let reopened = try await SQLiteAgentEventJournal.open(configuration: configuration)
    #expect(try await reopened.latestCheckpoint(for: runID)?.snapshot == .null)
    try await reopened.close()
  }

  @Test
  func successfulNonterminalAppendCannotConsumeRecoveryTerminalCapacity() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = SQLiteAgentEventJournalConfiguration(
      databaseURL: JournalTestSupport.databaseURL(in: directory),
      maximumRecoveryRecordCount: 2
    )
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    do {
      _ = try await journal.append(
        .messageAppended(Message(role: .user, content: [.text("at-capacity")])),
        to: runID
      )
      Issue.record("A nonterminal append consumed the reserved recovery record.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(error == .integrityRecordLimitExceeded(maximum: 2))
    }
    try await journal.close()

    do {
      let reopened = try await SQLiteAgentEventJournal.open(configuration: configuration)
      #expect(await reopened.recoveredRuns.map(\.runID) == [runID])
      try await reopened.close()
    } catch {
      Issue.record("A successful append left the journal unrecoverable: \(error)")
    }
  }

  @Test
  func successfulCheckpointCannotConsumeRecoveryTerminalCapacity() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = SQLiteAgentEventJournalConfiguration(
      databaseURL: JournalTestSupport.databaseURL(in: directory),
      maximumRecoveryRecordCount: 2
    )
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    do {
      _ = try await journal.writeCheckpoint(for: runID, through: 1, snapshot: .null)
      Issue.record("A checkpoint consumed the reserved recovery record.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(error == .integrityRecordLimitExceeded(maximum: 2))
    }
    try await journal.close()

    do {
      let reopened = try await SQLiteAgentEventJournal.open(configuration: configuration)
      #expect(await reopened.recoveredRuns.map(\.runID) == [runID])
      try await reopened.close()
    } catch {
      Issue.record("A successful checkpoint left the journal unrecoverable: \(error)")
    }
  }

  @Test
  func successfulNonterminalAppendCannotConsumeRecoveryByteCapacity() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let message = AgentEvent.messageAppended(
      Message(role: .user, content: [.text("at-byte-capacity")])
    )
    let runStarted = AgentEvent.runStarted
    let exactBytes =
      36
      + 36 + 36 + runStarted.journalKind.utf8.count
      + (try AgentEventCodec.encode(event: runStarted)).count
      + 36 + 36 + message.journalKind.utf8.count
      + (try AgentEventCodec.encode(event: message)).count
    let configuration = SQLiteAgentEventJournalConfiguration(
      databaseURL: JournalTestSupport.databaseURL(in: directory),
      maximumRecoveryBytes: exactBytes
    )
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(runStarted, to: runID)
    do {
      _ = try await journal.append(message, to: runID)
      Issue.record("A nonterminal append consumed the reserved recovery byte capacity.")
    } catch let error as SQLiteAgentEventJournalError {
      guard case .integrityByteLimitExceeded(let actual, let maximum) = error else {
        Issue.record("Expected integrityByteLimitExceeded, received \(error).")
        try await journal.close()
        return
      }
      #expect(actual > maximum)
      #expect(maximum == exactBytes)
    }
    try await journal.close()

    do {
      let reopened = try await SQLiteAgentEventJournal.open(configuration: configuration)
      #expect(await reopened.recoveredRuns.map(\.runID) == [runID])
      try await reopened.close()
    } catch {
      Issue.record("A successful append left the byte-bounded journal unrecoverable: \(error)")
    }
  }
}
