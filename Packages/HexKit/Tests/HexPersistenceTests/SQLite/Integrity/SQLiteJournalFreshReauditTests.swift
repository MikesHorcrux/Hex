import Foundation
import HexCore
import Synchronization
import Testing

@testable import HexPersistence

@Suite("Fresh persistence integrity re-audit")
struct SQLiteJournalFreshReauditTests {
  @Test
  func currentSchemaRejectsLowercaseUUIDWithoutConstraintBypass() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
    )
    try await journal.close()

    let lowercaseRunID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    do {
      try JournalTestSupport.execute(
        "INSERT INTO runs VALUES ('\(lowercaseRunID)', 1, NULL, 1, 1)",
        at: databaseURL
      )
      Issue.record("The v3 CHECK constraint admitted noncanonical lowercase UUID text.")
    } catch is SQLiteAgentEventJournalError {
      // Expected: the schema itself must reject noncanonical UUID text.
    }
  }

  @Test
  func recordsRejectCorruptUnrelatedTerminalRun() async throws {
    let fixture = try await makeTwoTerminalRuns()
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    try JournalTestSupport.execute(
      "UPDATE event_records SET payload = X'FF' WHERE run_id = '\(fixture.corruptRunID)' AND sequence = 1",
      at: fixture.databaseURL
    )

    do {
      let records = try await fixture.journal.records(
        for: fixture.targetRunID,
        after: nil,
        limit: 10
      )
      Issue.record("records returned \(records.count) rows while another durable run was corrupt.")
    } catch is SQLiteAgentEventJournalError {
      // Expected whole-journal fail-closed behavior in one read snapshot.
    }
    try await fixture.journal.close()
  }

  @Test
  func recordsForMissingRunRejectCorruptTerminalJournal() async throws {
    let fixture = try await makeTwoTerminalRuns()
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    try JournalTestSupport.execute(
      "UPDATE event_records SET payload = X'FF' WHERE run_id = '\(fixture.corruptRunID)' AND sequence = 1",
      at: fixture.databaseURL
    )

    do {
      let records = try await fixture.journal.records(for: AgentRunID(), after: nil, limit: 1)
      Issue.record("records returned \(records.count) rows without validating the corrupt journal.")
    } catch is SQLiteAgentEventJournalError {
      // Expected whole-journal fail-closed behavior in one read snapshot.
    }
    try await fixture.journal.close()
  }

  @Test
  func openRejectsCorruptJournalWhenNoRunNeedsRecovery() async throws {
    let fixture = try await makeTwoTerminalRuns()
    try await fixture.journal.close()
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    try JournalTestSupport.execute(
      "UPDATE event_records SET payload = X'FF' WHERE run_id = '\(fixture.corruptRunID)' AND sequence = 1",
      at: fixture.databaseURL
    )

    do {
      let reopened = try await SQLiteAgentEventJournal.open(
        configuration: SQLiteAgentEventJournalConfiguration(databaseURL: fixture.databaseURL)
      )
      try await reopened.close()
      Issue.record("Open skipped whole-journal validation because there were no interrupted runs.")
    } catch is SQLiteAgentEventJournalError {
      // Expected fail-closed recovery/open admission.
    }
  }

  @Test
  func appendDoesNotCreateLifecycleStateItsValidatorRejects() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: JournalTestSupport.configuration(in: directory)
    )
    let runID = AgentRunID()
    let call = ToolCall(id: ToolCallID(rawValue: "duplicate"), name: "noop", arguments: [:])
    _ = try await journal.append(.runStarted, to: runID)
    _ = try await journal.append(.toolStarted(call), to: runID)

    do {
      _ = try await journal.append(.toolStarted(call), to: runID)
      Issue.record("append created a duplicate tool-start history that recovery later rejects.")
    } catch is SQLiteAgentEventJournalError {
      // Expected prospective lifecycle validation before insertion.
    }
    let durable = try await journal.records(for: runID, after: nil, limit: 10)
    #expect(durable.map(\.sequence) == [1, 2])
    let finish = try await journal.append(
      .toolFinished(ToolResult(toolCallID: call.id, status: .success, output: .null)),
      to: runID
    )
    #expect(finish.sequence == 3)
    try await journal.close()
  }

  @Test
  func versionOneUUIDCollisionRollsBackAtomically() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    _ = try JournalTestSupport.createVersionOneFixture(at: databaseURL)
    let canonicalRunID = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
    try JournalTestSupport.execute(
      """
      INSERT INTO runs VALUES ('\(canonicalRunID)', 1, NULL, 1, 1);
      INSERT INTO runs VALUES ('\(canonicalRunID.lowercased())', 1, NULL, 1, 1);
      """,
      at: databaseURL
    )

    do {
      let migrated = try await SQLiteAgentEventJournal.open(
        configuration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
      )
      try await migrated.close()
      Issue.record("The v1 migration admitted a case-folded UUID collision.")
    } catch let error as SQLiteAgentEventJournalError {
      guard case .corruptSchema(let reason) = error, reason.contains("UUID collision") else {
        Issue.record("Expected UUID-collision corruption, received \(error).")
        return
      }
    }

    #expect(try JournalTestSupport.userVersion(at: databaseURL) == 1)
    #expect(try JournalTestSupport.tableExists("journal_checkpoints", at: databaseURL) == false)
  }

  @Test
  func directoryReplacementDuringAppendFailsBeforeCommit() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    let movedDirectory = directory.deletingLastPathComponent().appendingPathComponent(
      "\(directory.lastPathComponent)-moved",
      isDirectory: true
    )
    defer {
      JournalTestSupport.removeTemporaryDirectory(directory)
      JournalTestSupport.removeTemporaryDirectory(movedDirectory)
    }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let invocationCount = Mutex(0)
    let releaseClock = DispatchSemaphore(value: 0)
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: SQLiteAgentEventJournalConfiguration(
        databaseURL: databaseURL,
        clock: {
          let shouldBlock = invocationCount.withLock { count in
            count += 1
            return count == 2
          }
          if shouldBlock {
            releaseClock.wait()
          }
          return Date(timeIntervalSince1970: 1_700_000_000)
        }
      )
    )
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)

    let appendTask = Task {
      try await journal.append(
        .messageAppended(Message(role: .user, content: [.text("must-not-commit-to-moved-db")])),
        to: runID
      )
    }
    for _ in 0..<500 where invocationCount.withLock({ $0 }) < 2 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(invocationCount.withLock { $0 } == 2)
    try FileManager.default.moveItem(at: directory, to: movedDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let second = try await SQLiteAgentEventJournal.open(
      configuration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
    )
    releaseClock.signal()

    do {
      _ = try await appendTask.value
      Issue.record("An in-flight append committed after its anchored directory path was replaced.")
    } catch is SQLiteAgentEventJournalError {
      // Expected: revalidate the ownership boundary before durable commit.
    }
    try await second.close()
    try await journal.close()
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM event_records",
        at: JournalTestSupport.databaseURL(in: movedDirectory)
      ) == 1
    )
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM event_records",
        at: databaseURL
      ) == 0
    )
  }

  @Test
  func databasePathRemovalDuringAppendCannotReturnDurableSuccess() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let invocationCount = Mutex(0)
    let releaseClock = DispatchSemaphore(value: 0)
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: SQLiteAgentEventJournalConfiguration(
        databaseURL: databaseURL,
        clock: {
          let shouldBlock = invocationCount.withLock { count in
            count += 1
            return count == 2
          }
          if shouldBlock {
            releaseClock.wait()
          }
          return Date(timeIntervalSince1970: 1_700_000_000)
        }
      )
    )
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)

    let appendTask = Task {
      try await journal.append(
        .messageAppended(Message(role: .user, content: [.text("reported-durable-but-unlinked")])),
        to: runID
      )
    }
    for _ in 0..<500 where invocationCount.withLock({ $0 }) < 2 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(invocationCount.withLock { $0 } == 2)
    try FileManager.default.removeItem(at: databaseURL)
    releaseClock.signal()

    do {
      _ = try await appendTask.value
      Issue.record("append reported durable success after its database path was unlinked.")
    } catch is SQLiteAgentEventJournalError {
      // Expected: identity must be revalidated before commit/success publication.
    }
    try await journal.close()
  }

  @Test
  func postCommitValidationFailureReportsUncertainOutcomeAndInvalidatesConnection() throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let connection = try JournalTestSupport.makeConnection(
      at: databaseURL,
      busyTimeoutMilliseconds: 1_000
    )
    try connection.execute("CREATE TABLE committed_value (value INTEGER NOT NULL)")

    do {
      try connection.withImmediateTransaction(
        afterCommit: {
          throw SQLiteAgentEventJournalError.invalidConfiguration(
            "Injected ownership replacement after commit."
          )
        },
        {
          try connection.execute("INSERT INTO committed_value VALUES (1)")
        }
      )
      Issue.record("A failed post-commit ownership check reported ordinary success.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(error == .commitOutcomeUncertain)
    }

    do {
      _ = try connection.scalarInt64("SELECT COUNT(*) FROM committed_value")
      Issue.record("The connection remained usable after an uncertain commit outcome.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(error == .closed)
    }
    let observer = try JournalTestSupport.makeConnection(
      at: databaseURL,
      busyTimeoutMilliseconds: 1_000
    )
    #expect(try observer.scalarInt64("SELECT COUNT(*) FROM committed_value") == 1)
    try observer.close()
  }

  private func makeTwoTerminalRuns() async throws -> (
    directory: URL,
    databaseURL: URL,
    journal: SQLiteAgentEventJournal,
    targetRunID: AgentRunID,
    corruptRunID: AgentRunID
  ) {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
    )
    let targetRunID = AgentRunID()
    let corruptRunID = AgentRunID()
    for runID in [targetRunID, corruptRunID] {
      _ = try await journal.append(.runStarted, to: runID)
      _ = try await journal.append(.runCompleted, to: runID)
    }
    return (directory, databaseURL, journal, targetRunID, corruptRunID)
  }
}
