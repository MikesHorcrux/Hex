import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("SQLite agent-event journal recovery")
struct SQLiteAgentEventJournalRecoveryTests {
  @Test
  func recoversInterruptedRunsExactlyOnceWithoutReplayingTools() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let unresolvedRun = AgentRunID()
    let resolvedRun = AgentRunID()
    let deniedFinishOnlyRun = AgentRunID()
    let terminalRun = AgentRunID()
    let unresolvedCall = ToolCall(
      id: ToolCallID(rawValue: "call-unresolved"),
      name: "terminal",
      arguments: ["command": .string("sensitive-command")]
    )
    let resolvedCall = ToolCall(
      id: ToolCallID(rawValue: "call-resolved"),
      name: "read_file",
      arguments: ["path": .string("/private/example")]
    )
    let deniedCallID = ToolCallID(rawValue: "call-denied-before-start")
    let denialRequestID = AuthorizationRequestID()
    let denialRequest = AuthorizationRequest(
      id: denialRequestID,
      runID: deniedFinishOnlyRun,
      toolCallID: deniedCallID,
      capability: CapabilityID(rawValue: "filesystem.read"),
      operation: "read",
      explanation: "Read a protected file."
    )
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)

    _ = try await journal.append(.runStarted, to: unresolvedRun)
    _ = try await journal.append(.toolStarted(unresolvedCall), to: unresolvedRun)

    _ = try await journal.append(.runStarted, to: resolvedRun)
    _ = try await journal.append(.toolStarted(resolvedCall), to: resolvedRun)
    _ = try await journal.append(
      .toolFinished(
        ToolResult(toolCallID: resolvedCall.id, status: .success, output: .string("private"))
      ),
      to: resolvedRun
    )

    _ = try await journal.append(.runStarted, to: deniedFinishOnlyRun)
    _ = try await journal.append(.authorizationRequested(denialRequest), to: deniedFinishOnlyRun)
    _ = try await journal.append(
      .authorizationDecided(requestID: denialRequestID, decision: .deny(reason: "Not granted")),
      to: deniedFinishOnlyRun
    )
    _ = try await journal.append(
      .toolFinished(
        ToolResult(
          toolCallID: deniedCallID,
          status: .failure,
          output: .string("Authorization denied.")
        )
      ),
      to: deniedFinishOnlyRun
    )

    _ = try await journal.append(.runStarted, to: terminalRun)
    _ = try await journal.append(.runCompleted, to: terminalRun)
    try await journal.close()

    let recovered = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let recoveryReports = await recovered.recoveredRuns
    let reportByRun = Dictionary(
      uniqueKeysWithValues: recoveryReports.map {
        ($0.runID, $0.unresolvedToolCallIDs)
      }
    )
    #expect(reportByRun.count == 3)
    #expect(reportByRun[unresolvedRun] == [unresolvedCall.id])
    #expect(reportByRun[resolvedRun] == [])
    #expect(reportByRun[deniedFinishOnlyRun] == [])
    #expect(reportByRun[terminalRun] == nil)

    let unresolvedRecords = try await recovered.records(
      for: unresolvedRun,
      after: nil,
      limit: 10
    )
    guard case .runFailed(let failure) = unresolvedRecords.last?.event else {
      Issue.record("Expected recovery to append runFailed.")
      try await recovered.close()
      return
    }
    #expect(failure.code == .invalidState)
    #expect(failure.message == "Run interrupted before reaching a terminal state.")
    #expect(failure.isRetryable == false)
    let terminalRecords = try await recovered.records(for: terminalRun, after: nil, limit: 10)
    #expect(terminalRecords.map(\.event) == [.runStarted, .runCompleted])
    try await recovered.close()

    let secondOpen = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let secondRecoveryReports = await secondOpen.recoveredRuns
    #expect(secondRecoveryReports.isEmpty)
    let secondPassRecords = try await secondOpen.records(
      for: unresolvedRun,
      after: nil,
      limit: 10
    )
    #expect(secondPassRecords.count == unresolvedRecords.count)
    try await secondOpen.close()
  }

  @Test
  func corruptInterruptedMetadataFailsBeforeRecoveryMutation() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let runID = AgentRunID()
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    _ = try await journal.append(.runStarted, to: runID)
    _ = try await journal.append(
      .toolStarted(
        ToolCall(
          id: ToolCallID(rawValue: "real-call"),
          name: "noop",
          arguments: [:]
        )
      ),
      to: runID
    )
    try await journal.close()
    try JournalTestSupport.execute(
      "UPDATE event_records SET tool_call_id = 'forged-call' WHERE run_id = '\(runID)' AND sequence = 2",
      at: configuration.databaseURL
    )

    do {
      _ = try await SQLiteAgentEventJournal.open(configuration: configuration)
      Issue.record("Expected corrupt interrupted metadata to fail open.")
    } catch let error as SQLiteAgentEventJournalError {
      if case .corruptRecord = error {
        // Expected.
      } else {
        Issue.record("Expected corruptRecord, received \(error).")
      }
    }
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM event_records WHERE run_id = '\(runID)'",
        at: configuration.databaseURL
      ) == 2
    )
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM runs WHERE run_id = '\(runID)' AND terminal_sequence IS NOT NULL",
        at: configuration.databaseURL
      ) == 0
    )
  }

  @Test
  func inconsistentNextSequenceFailsBeforeRecoveryMutation() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let runID = AgentRunID()
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    _ = try await journal.append(.runStarted, to: runID)
    try await journal.close()
    try JournalTestSupport.execute(
      "UPDATE runs SET next_sequence = 99 WHERE run_id = '\(runID)'",
      at: configuration.databaseURL
    )

    do {
      _ = try await SQLiteAgentEventJournal.open(configuration: configuration)
      Issue.record("Expected inconsistent sequence state to fail open.")
    } catch let error as SQLiteAgentEventJournalError {
      if case .corruptRecord = error {
        // Expected.
      } else {
        Issue.record("Expected corruptRecord, received \(error).")
      }
    }
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM event_records WHERE run_id = '\(runID)'",
        at: configuration.databaseURL
      ) == 1
    )
  }

  @Test
  func ambiguousToolHistoriesFailBeforeRecoveryMutation() async throws {
    let call = ToolCall(
      id: ToolCallID(rawValue: "ambiguous-call"),
      name: "noop",
      arguments: [:]
    )
    let success = ToolResult(toolCallID: call.id, status: .success, output: .null)
    let failure = ToolResult(toolCallID: call.id, status: .failure, output: .null)
    let fixtures: [(name: String, events: [AgentEvent])] = [
      ("duplicate start", [.runStarted, .toolStarted(call), .toolStarted(call)]),
      ("orphan success", [.runStarted, .toolFinished(success)]),
      ("unproven orphan failure", [.runStarted, .toolFinished(failure)]),
      (
        "repeated finish",
        [.runStarted, .toolStarted(call), .toolFinished(success), .toolFinished(success)]
      ),
    ]
    var directories: [URL] = []
    defer {
      for directory in directories {
        JournalTestSupport.removeTemporaryDirectory(directory)
      }
    }

    for fixture in fixtures {
      let directory = try JournalTestSupport.makeTemporaryDirectory()
      directories.append(directory)
      let configuration = JournalTestSupport.configuration(in: directory)
      let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
      let runID = AgentRunID()
      for event in fixture.events.dropLast() {
        _ = try await journal.append(event, to: runID)
      }
      try await journal.close()
      guard let hostileEvent = fixture.events.last else {
        Issue.record("Expected a hostile terminal fixture event.")
        continue
      }
      try injectHostileEvent(
        hostileEvent,
        sequence: fixture.events.count,
        runID: runID,
        databaseURL: configuration.databaseURL
      )

      do {
        let recovered = try await SQLiteAgentEventJournal.open(configuration: configuration)
        try await recovered.close()
        Issue.record("Expected \(fixture.name) to fail recovery.")
      } catch let error as SQLiteAgentEventJournalError {
        if case .corruptRecord = error {
          // Expected.
        } else {
          Issue.record("Expected corruptRecord for \(fixture.name), received \(error).")
        }
      }
      #expect(
        try JournalTestSupport.scalarInt64(
          "SELECT COUNT(*) FROM event_records WHERE run_id = '\(runID)'",
          at: configuration.databaseURL
        ) == Int64(fixture.events.count)
      )
      #expect(
        try JournalTestSupport.scalarInt64(
          "SELECT COUNT(*) FROM runs WHERE run_id = '\(runID)' AND terminal_sequence IS NOT NULL",
          at: configuration.databaseURL
        ) == 0
      )
    }
  }

  private func injectHostileEvent(
    _ event: AgentEvent,
    sequence: Int,
    runID: AgentRunID,
    databaseURL: URL
  ) throws {
    try JournalTestSupport.withConnection(at: databaseURL) { connection in
      try connection.withImmediateTransaction {
        let insert = try connection.prepare(
          """
          INSERT INTO event_records (
            event_id, run_id, sequence, timestamp_us, record_schema_version, kind, tool_call_id,
            payload
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          """
        )
        try insert.bind(AgentEventID().description, at: 1)
        try insert.bind(runID.description, at: 2)
        try insert.bind(Int64(sequence), at: 3)
        try insert.bind(Int64(sequence), at: 4)
        try insert.bind(Int64(AgentEventCodec.recordSchemaVersion), at: 5)
        try insert.bind(event.journalKind, at: 6)
        if let toolCallID = event.journalToolCallID {
          try insert.bind(toolCallID.rawValue, at: 7)
        } else {
          try insert.bindNull(at: 7)
        }
        try insert.bind(try AgentEventCodec.encode(event: event), at: 8)
        _ = try insert.step()

        let update = try connection.prepare(
          "UPDATE runs SET next_sequence = ?, updated_at_us = ? WHERE run_id = ?"
        )
        try update.bind(Int64(sequence + 1), at: 1)
        try update.bind(Int64(sequence), at: 2)
        try update.bind(runID.description, at: 3)
        _ = try update.step()
      }
    }
  }

  @Test
  func recoveryRunCountIsBoundedBeforeMutation() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let writeConfiguration = SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
    let recoveryConfiguration = SQLiteAgentEventJournalConfiguration(
      databaseURL: databaseURL,
      maximumRecoveryRunCount: 1
    )
    let journal = try await SQLiteAgentEventJournal.open(configuration: writeConfiguration)
    let firstRunID = AgentRunID()
    let secondRunID = AgentRunID()
    _ = try await journal.append(.runStarted, to: firstRunID)
    _ = try await journal.append(.runStarted, to: secondRunID)
    try await journal.close()

    do {
      _ = try await SQLiteAgentEventJournal.open(configuration: recoveryConfiguration)
      Issue.record("Expected the recovery run-count limit to fail open.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(error == .recoveryRunLimitExceeded(maximum: 1))
    }
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM runs WHERE terminal_sequence IS NOT NULL",
        at: databaseURL
      ) == 0
    )
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM event_records",
        at: databaseURL
      ) == 2
    )
  }

  @Test
  func recoveryRecordCountIsBoundedBeforeMutation() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let writeConfiguration = SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
    let recoveryConfiguration = SQLiteAgentEventJournalConfiguration(
      databaseURL: databaseURL,
      maximumRecoveryRecordCount: 2
    )
    let journal = try await SQLiteAgentEventJournal.open(configuration: writeConfiguration)
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    for value in ["one", "two"] {
      _ = try await journal.append(
        .messageAppended(Message(role: .user, content: [.text(value)])),
        to: runID
      )
    }
    try await journal.close()

    do {
      _ = try await SQLiteAgentEventJournal.open(configuration: recoveryConfiguration)
      Issue.record("Expected the recovery record-count limit to fail open.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(error == .recoveryRecordLimitExceeded(maximum: 2))
    }
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM event_records WHERE run_id = '\(runID)'",
        at: databaseURL
      ) == 3
    )
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM runs WHERE run_id = '\(runID)' AND terminal_sequence IS NOT NULL",
        at: databaseURL
      ) == 0
    )
  }

  @Test
  func recoveryByteBudgetIsBoundedBeforeMutation() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let writeConfiguration = SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
    let recoveryConfiguration = SQLiteAgentEventJournalConfiguration(
      databaseURL: databaseURL,
      maximumRecoveryBytes: 36
    )
    let journal = try await SQLiteAgentEventJournal.open(configuration: writeConfiguration)
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    try await journal.close()

    do {
      _ = try await SQLiteAgentEventJournal.open(configuration: recoveryConfiguration)
      Issue.record("Expected the recovery byte budget to fail open.")
    } catch let error as SQLiteAgentEventJournalError {
      if case .recoveryByteLimitExceeded(let actual, let maximum) = error {
        #expect(actual > maximum)
        #expect(maximum == 36)
      } else {
        Issue.record("Expected recoveryByteLimitExceeded, received \(error).")
      }
    }
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM event_records WHERE run_id = '\(runID)'",
        at: databaseURL
      ) == 1
    )
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM runs WHERE run_id = '\(runID)' AND terminal_sequence IS NOT NULL",
        at: databaseURL
      ) == 0
    )
  }

  @Test
  func oversizedInterruptedTextFailsBeforeRecoveryMutation() async throws {
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
      _ = try await SQLiteAgentEventJournal.open(configuration: configuration)
      Issue.record("Expected oversized interrupted text to fail open.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(error == .textTooLarge(actual: 41, maximum: 40))
    }
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM event_records WHERE run_id = '\(runID)'",
        at: configuration.databaseURL
      ) == 2
    )
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM runs WHERE run_id = '\(runID)' AND terminal_sequence IS NOT NULL",
        at: configuration.databaseURL
      ) == 0
    )
  }
}
