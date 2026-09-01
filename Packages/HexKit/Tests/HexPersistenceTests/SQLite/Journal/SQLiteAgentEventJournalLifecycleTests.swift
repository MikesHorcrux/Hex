import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("SQLite agent-event journal lifecycle")
struct SQLiteAgentEventJournalLifecycleTests {
  @Test
  func exclusiveFileLockPreventsSimultaneousOwnership() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let first = try await SQLiteAgentEventJournal.open(configuration: configuration)

    do {
      _ = try await SQLiteAgentEventJournal.open(configuration: configuration)
      Issue.record("Expected simultaneous ownership to fail.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(error == .ownershipUnavailable)
    }

    try await first.close()
    let reopened = try await SQLiteAgentEventJournal.open(configuration: configuration)
    try await reopened.close()
  }

  @Test
  func cancellationBeforeTransactionDoesNotAppend() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: JournalTestSupport.configuration(in: directory)
    )
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    let task = Task {
      await Task.yield()
      return try await journal.append(
        .messageAppended(Message(role: .user, content: [.text("cancelled")])),
        to: runID
      )
    }
    task.cancel()

    do {
      _ = try await task.value
      Issue.record("Expected append cancellation.")
    } catch is CancellationError {
      // Cancellation was observed before BEGIN IMMEDIATE.
    }
    let records = try await journal.records(for: runID, after: nil, limit: 10)
    #expect(records.map(\.sequence) == [1])
    try await journal.close()
  }

  @Test
  func cancellationAfterTransactionBeginsReturnsCommittedRecord() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = SQLiteAgentEventJournalConfiguration(
      databaseURL: JournalTestSupport.databaseURL(in: directory),
      clock: {
        withUnsafeCurrentTask { task in
          task?.cancel()
        }
        return Date(timeIntervalSince1970: 1_700_000_000)
      }
    )
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    let task = Task {
      try await journal.append(.runStarted, to: runID)
    }

    let record = try await task.value
    #expect(task.isCancelled)
    #expect(record.sequence == 1)
    let durable = try await journal.records(for: runID, after: nil, limit: 10)
    #expect(durable.map(\.sequence) == [1])
    try await journal.close()
  }

  @Test
  func rejectsNonpositiveAndOversizedConfigurationBounds() async {
    let directory: URL
    do {
      directory = try JournalTestSupport.makeTemporaryDirectory()
    } catch {
      Issue.record("Could not create temporary directory: \(error)")
      return
    }
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let configurations = [
      SQLiteAgentEventJournalConfiguration(
        databaseURL: databaseURL,
        busyTimeoutMilliseconds: 0
      ),
      SQLiteAgentEventJournalConfiguration(
        databaseURL: databaseURL,
        busyTimeoutMilliseconds:
          SQLiteAgentEventJournalConfiguration.hardMaximumBusyTimeoutMilliseconds + 1
      ),
      SQLiteAgentEventJournalConfiguration(
        databaseURL: databaseURL,
        busyTimeoutMilliseconds: Int.max
      ),
      SQLiteAgentEventJournalConfiguration(
        databaseURL: databaseURL,
        maximumReadLimit: 0
      ),
      SQLiteAgentEventJournalConfiguration(
        databaseURL: databaseURL,
        maximumReadLimit: Int.max
      ),
      SQLiteAgentEventJournalConfiguration(
        databaseURL: databaseURL,
        maximumPayloadBytes: 0
      ),
      SQLiteAgentEventJournalConfiguration(
        databaseURL: databaseURL,
        maximumPayloadBytes: Int.max
      ),
      SQLiteAgentEventJournalConfiguration(
        databaseURL: databaseURL,
        maximumReadBytes: 0
      ),
      SQLiteAgentEventJournalConfiguration(
        databaseURL: databaseURL,
        maximumReadBytes: Int.max
      ),
      SQLiteAgentEventJournalConfiguration(
        databaseURL: databaseURL,
        maximumTextBytes: 35
      ),
      SQLiteAgentEventJournalConfiguration(
        databaseURL: databaseURL,
        maximumTextBytes: Int.max
      ),
      SQLiteAgentEventJournalConfiguration(
        databaseURL: databaseURL,
        maximumRecoveryRunCount: 0
      ),
      SQLiteAgentEventJournalConfiguration(
        databaseURL: databaseURL,
        maximumRecoveryRunCount: Int.max
      ),
      SQLiteAgentEventJournalConfiguration(
        databaseURL: databaseURL,
        maximumRecoveryRecordCount: 0
      ),
      SQLiteAgentEventJournalConfiguration(
        databaseURL: databaseURL,
        maximumRecoveryRecordCount: Int.max
      ),
      SQLiteAgentEventJournalConfiguration(
        databaseURL: databaseURL,
        maximumRecoveryBytes: 0
      ),
      SQLiteAgentEventJournalConfiguration(
        databaseURL: databaseURL,
        maximumRecoveryBytes: Int.max
      ),
      SQLiteAgentEventJournalConfiguration(
        databaseURL: databaseURL,
        maximumDatabaseBytes: 0
      ),
      SQLiteAgentEventJournalConfiguration(
        databaseURL: databaseURL,
        maximumDatabaseBytes: Int.max
      ),
    ]

    for configuration in configurations {
      do {
        _ = try await SQLiteAgentEventJournal.open(configuration: configuration)
        Issue.record("Expected invalid configuration to fail.")
      } catch let error as SQLiteAgentEventJournalError {
        if case .invalidConfiguration = error {
          // Expected.
        } else {
          Issue.record("Expected invalidConfiguration, received \(error).")
        }
      } catch {
        Issue.record("Expected journal error, received \(error).")
      }
    }
  }
}
