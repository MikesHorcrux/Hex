import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("SQLite agent-event journal append")
struct SQLiteAgentEventJournalAppendTests {
  @Test
  func sequencesRunsIndependentlyAndPersistsAcrossReopen() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let firstRun = AgentRunID()
    let secondRun = AgentRunID()
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)

    let firstStart = try await journal.append(.runStarted, to: firstRun)
    let firstMessage = try await journal.append(
      .messageAppended(Message(role: .user, content: [.text("hello")])),
      to: firstRun
    )
    let secondStart = try await journal.append(.runStarted, to: secondRun)

    #expect(firstStart.sequence == 1)
    #expect(firstMessage.sequence == 2)
    #expect(secondStart.sequence == 1)
    try await journal.close()

    let reopened = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let firstRecords = try await reopened.records(for: firstRun, after: nil, limit: 10)
    let secondRecords = try await reopened.records(for: secondRun, after: nil, limit: 10)
    #expect(firstRecords.map(\.sequence) == [1, 2, 3])
    #expect(
      firstRecords.last?.event
        == .runFailed(
          AgentFailure(
            code: .invalidState,
            message: "Run interrupted before reaching a terminal state.",
            isRetryable: false
          )
        ))
    #expect(secondRecords.map(\.sequence) == [1, 2])
    try await reopened.close()
  }

  @Test
  func concurrentAppendsAreUniqueAndContiguous() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: JournalTestSupport.configuration(in: directory)
    )
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)

    let appended = try await withThrowingTaskGroup(
      of: AgentEventRecord.self,
      returning: [AgentEventRecord].self
    ) { group in
      for index in 0..<20 {
        group.addTask {
          try await journal.append(
            .messageAppended(Message(role: .assistant, content: [.text("message-\(index)")])),
            to: runID
          )
        }
      }
      var records: [AgentEventRecord] = []
      for try await record in group {
        records.append(record)
      }
      return records
    }

    #expect(appended.map(\.sequence).sorted() == Array(2...21).map(UInt64.init))
    #expect(Set(appended.map(\.id)).count == 20)
    let durable = try await journal.records(for: runID, after: nil, limit: 100)
    #expect(durable.map(\.sequence) == Array(1...21).map(UInt64.init))
    try await journal.close()
  }

  @Test
  func failedAppendRollsBackWithoutSequenceGap() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: JournalTestSupport.configuration(in: directory)
    )
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    let invalidCall = ToolCall(
      name: "invalid",
      arguments: ["integralDouble": .number(42.0)]
    )

    do {
      _ = try await journal.append(.toolStarted(invalidCall), to: runID)
      Issue.record("Expected noncanonical JSON to reject encoding.")
    } catch is EncodingError {
      // The transaction must roll back the sequence increment.
    }

    let next = try await journal.append(
      .messageAppended(Message(role: .user, content: [.text("valid")])),
      to: runID
    )
    #expect(next.sequence == 2)
    try await journal.close()
  }

  @Test
  func oversizedAppendRollsBackWithoutSequenceGap() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = SQLiteAgentEventJournalConfiguration(
      databaseURL: JournalTestSupport.databaseURL(in: directory),
      maximumPayloadBytes: 128
    )
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)

    do {
      _ = try await journal.append(
        .messageAppended(
          Message(role: .user, content: [.text(String(repeating: "x", count: 1_000))])
        ),
        to: runID
      )
      Issue.record("Expected oversized append to fail.")
    } catch let error as SQLiteAgentEventJournalError {
      if case .payloadTooLarge = error {
        // Expected.
      } else {
        Issue.record("Expected payloadTooLarge, received \(error).")
      }
    }

    let next = try await journal.append(.runCompleted, to: runID)
    #expect(next.sequence == 2)
    try await journal.close()
  }

  @Test
  func terminalRunRejectsFurtherAppends() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: JournalTestSupport.configuration(in: directory)
    )
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    _ = try await journal.append(.runCompleted, to: runID)

    do {
      _ = try await journal.append(.runCancelled, to: runID)
      Issue.record("Expected a terminal run to reject another event.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(error == .runAlreadyTerminal(runID))
    }
    try await journal.close()
  }

  @Test
  func preservesEmbeddedNullInToolCallIdentifier() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: JournalTestSupport.configuration(in: directory)
    )
    let runID = AgentRunID()
    let call = ToolCall(
      id: ToolCallID(rawValue: "provider\0call"),
      name: "noop",
      arguments: [:]
    )
    _ = try await journal.append(.runStarted, to: runID)
    _ = try await journal.append(.toolStarted(call), to: runID)
    _ = try await journal.append(.runCompleted, to: runID)

    let records = try await journal.records(for: runID, after: nil, limit: 10)
    #expect(records.dropFirst().first?.event == .toolStarted(call))
    try await journal.close()
  }

  @Test
  func oversizedMetadataTextRollsBackWithoutSequenceGap() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = SQLiteAgentEventJournalConfiguration(
      databaseURL: JournalTestSupport.databaseURL(in: directory),
      maximumTextBytes: 40
    )
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    let call = ToolCall(
      id: ToolCallID(rawValue: String(repeating: "x", count: 41)),
      name: "noop",
      arguments: [:]
    )

    do {
      _ = try await journal.append(.toolStarted(call), to: runID)
      Issue.record("Expected oversized metadata text to fail.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(error == .textTooLarge(actual: 41, maximum: 40))
    }
    let terminal = try await journal.append(.runCompleted, to: runID)
    #expect(terminal.sequence == 2)
    try await journal.close()
  }
}
