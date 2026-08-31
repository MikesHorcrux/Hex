import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("SQLite agent-event journal reads")
struct SQLiteAgentEventJournalReadTests {
  @Test
  func readsAreBoundedAscendingAndAfterExclusive() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory, maximumReadLimit: 3)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    for value in ["one", "two", "three"] {
      _ = try await journal.append(
        .messageAppended(Message(role: .user, content: [.text(value)])),
        to: runID
      )
    }
    _ = try await journal.append(.runCompleted, to: runID)

    let firstPage = try await journal.records(for: runID, after: nil, limit: 3)
    let secondPage = try await journal.records(for: runID, after: 2, limit: 3)
    let beyondRange = try await journal.records(for: runID, after: UInt64.max, limit: 3)
    #expect(firstPage.map(\.sequence) == [1, 2, 3])
    #expect(secondPage.map(\.sequence) == [3, 4, 5])
    #expect(beyondRange.isEmpty)

    for invalidLimit in [0, 4] {
      do {
        _ = try await journal.records(for: runID, after: nil, limit: invalidLimit)
        Issue.record("Expected invalid limit \(invalidLimit) to fail.")
      } catch let error as SQLiteAgentEventJournalError {
        #expect(error == .invalidReadLimit(requested: invalidLimit, maximum: 3))
      }
    }
    try await journal.close()
  }

  @Test
  func corruptPayloadFailsClosed() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let runID = try await makeTerminalRun(configuration: configuration)
    try JournalTestSupport.execute(
      "UPDATE event_records SET payload = X'FF' WHERE run_id = '\(runID)' AND sequence = 1",
      at: configuration.databaseURL
    )

    do {
      let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
      try await journal.close()
      Issue.record("Expected corrupt payload to fail during open admission.")
    } catch is SQLiteAgentEventJournalError {
      // A typed journal error is the fail-closed boundary.
    }
  }

  @Test
  func mismatchedKindFailsClosed() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    let call = ToolCall(id: ToolCallID(rawValue: "call-real"), name: "noop", arguments: [:])
    _ = try await journal.append(.runStarted, to: runID)
    _ = try await journal.append(.toolStarted(call), to: runID)
    _ = try await journal.append(
      .toolFinished(ToolResult(toolCallID: call.id, status: .success, output: .null)),
      to: runID
    )
    _ = try await journal.append(.runCompleted, to: runID)
    try await journal.close()

    try JournalTestSupport.execute(
      """
      UPDATE event_records
      SET kind = 'message_appended'
      WHERE run_id = '\(runID)' AND sequence = 2
      """,
      at: configuration.databaseURL
    )
    do {
      let reopened = try await SQLiteAgentEventJournal.open(configuration: configuration)
      try await reopened.close()
      Issue.record("Expected mismatched metadata to fail during open admission.")
    } catch let error as SQLiteAgentEventJournalError {
      if case .corruptRecord = error {
        // Expected.
      } else {
        Issue.record("Expected corruptRecord, received \(error).")
      }
    }
  }

  @Test
  func mismatchedToolIdentifierFailsClosed() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    let call = ToolCall(id: ToolCallID(rawValue: "call-real"), name: "noop", arguments: [:])
    _ = try await journal.append(.runStarted, to: runID)
    _ = try await journal.append(.toolStarted(call), to: runID)
    _ = try await journal.append(
      .toolFinished(ToolResult(toolCallID: call.id, status: .success, output: .null)),
      to: runID
    )
    _ = try await journal.append(.runCompleted, to: runID)
    try await journal.close()
    try JournalTestSupport.execute(
      """
      UPDATE event_records
      SET tool_call_id = 'call-forged'
      WHERE run_id = '\(runID)' AND sequence = 2
      """,
      at: configuration.databaseURL
    )

    do {
      let reopened = try await SQLiteAgentEventJournal.open(configuration: configuration)
      try await reopened.close()
      Issue.record("Expected mismatched tool metadata to fail during open admission.")
    } catch let error as SQLiteAgentEventJournalError {
      if case .corruptRecord = error {
        // Expected.
      } else {
        Issue.record("Expected corruptRecord, received \(error).")
      }
    }
  }

  @Test
  func futureRecordSchemaFailsClosed() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let runID = try await makeTerminalRun(configuration: configuration)
    try JournalTestSupport.execute(
      "UPDATE event_records SET record_schema_version = 2 WHERE run_id = '\(runID)' AND sequence = 1",
      at: configuration.databaseURL
    )

    do {
      let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
      try await journal.close()
      Issue.record("Expected a future record schema to fail during open admission.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(error == .unsupportedRecordSchemaVersion(2))
    }
  }

  @Test
  func oversizedStoredPayloadFailsBeforeDecode() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let writeConfiguration = SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
    let readConfiguration = SQLiteAgentEventJournalConfiguration(
      databaseURL: databaseURL,
      maximumPayloadBytes: 64
    )
    let runID = try await makeTerminalRun(configuration: writeConfiguration)
    try JournalTestSupport.execute(
      "UPDATE event_records SET payload = zeroblob(65) WHERE run_id = '\(runID)' AND sequence = 1",
      at: databaseURL
    )

    do {
      let journal = try await SQLiteAgentEventJournal.open(configuration: readConfiguration)
      try await journal.close()
      Issue.record("Expected oversized stored payload to fail during open admission.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(error == .payloadTooLarge(actual: 65, maximum: 64))
    }
  }

  @Test
  func pageByteBudgetBoundsAggregateDecodedRecords() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let events: [AgentEvent] = [.runStarted, .runCompleted]
    let expectedBytes = try events.reduce(0) { byteCount, event in
      let payload = try AgentEventCodec.encode(event: event)
      return byteCount + 72 + event.journalKind.utf8.count + payload.count
    }
    let configuration = SQLiteAgentEventJournalConfiguration(
      databaseURL: JournalTestSupport.databaseURL(in: directory),
      maximumReadBytes: expectedBytes - 1
    )
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    for event in events {
      _ = try await journal.append(event, to: runID)
    }

    do {
      _ = try await journal.records(for: runID, after: nil, limit: 2)
      Issue.record("Expected the aggregate read byte budget to fail closed.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(
        error
          == .readByteLimitExceeded(
            actual: expectedBytes,
            maximum: expectedBytes - 1
          )
      )
    }
    try await journal.close()
  }

  @Test
  func oversizedStoredTextFailsBeforeAllocation() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = SQLiteAgentEventJournalConfiguration(
      databaseURL: JournalTestSupport.databaseURL(in: directory),
      maximumTextBytes: 40
    )
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    let call = ToolCall(
      id: ToolCallID(rawValue: "short-call"),
      name: "noop",
      arguments: [:]
    )
    _ = try await journal.append(.runStarted, to: runID)
    _ = try await journal.append(.toolStarted(call), to: runID)
    _ = try await journal.append(
      .toolFinished(ToolResult(toolCallID: call.id, status: .success, output: .null)),
      to: runID
    )
    _ = try await journal.append(.runCompleted, to: runID)
    try await journal.close()
    let oversizedText = String(repeating: "x", count: 41)
    try JournalTestSupport.execute(
      """
      UPDATE event_records
      SET tool_call_id = '\(oversizedText)'
      WHERE run_id = '\(runID)' AND sequence = 2
      """,
      at: configuration.databaseURL
    )

    do {
      let reopened = try await SQLiteAgentEventJournal.open(configuration: configuration)
      try await reopened.close()
      Issue.record("Expected oversized stored text to fail during open admission.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(error == .textTooLarge(actual: 41, maximum: 40))
    }
  }

  private func makeTerminalRun(
    configuration: SQLiteAgentEventJournalConfiguration
  ) async throws -> AgentRunID {
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    _ = try await journal.append(.runCompleted, to: runID)
    try await journal.close()
    return runID
  }
}
