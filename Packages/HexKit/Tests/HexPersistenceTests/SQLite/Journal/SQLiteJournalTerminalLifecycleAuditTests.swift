import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("Persistence terminal lifecycle audit")
struct SQLiteJournalTerminalLifecycleAuditTests {
  @Test
  func runCompletedCannotCommitWithAnUnresolvedStartedTool() async throws {
    let fixture = try await makeJournal()
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    let call = ToolCall(id: ToolCallID(rawValue: "still-running"), name: "noop", arguments: [:])
    _ = try await fixture.journal.append(.runStarted, to: fixture.runID)
    _ = try await fixture.journal.append(.toolStarted(call), to: fixture.runID)

    do {
      _ = try await fixture.journal.append(.runCompleted, to: fixture.runID)
      Issue.record("runCompleted committed while a started tool had no durable outcome.")
    } catch is SQLiteAgentEventJournalError {
      // Expected candidate lifecycle rejection and rollback.
    }

    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM event_records WHERE run_id = '\(fixture.runID)'",
        at: JournalTestSupport.databaseURL(in: fixture.directory)
      ) == 2
    )
    try await fixture.journal.close()
  }

  @Test
  func runCompletedCannotCommitWithAnUndecidedAuthorizationRequest() async throws {
    let fixture = try await makeJournal()
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    let request = AuthorizationRequest(
      runID: fixture.runID,
      capability: CapabilityID(rawValue: "audit"),
      operation: "inspect",
      explanation: "Audit fixture"
    )
    _ = try await fixture.journal.append(.runStarted, to: fixture.runID)
    _ = try await fixture.journal.append(.authorizationRequested(request), to: fixture.runID)

    do {
      _ = try await fixture.journal.append(.runCompleted, to: fixture.runID)
      Issue.record("runCompleted committed while authorization remained undecided.")
    } catch is SQLiteAgentEventJournalError {
      // Expected candidate lifecycle rejection and rollback.
    }

    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM event_records WHERE run_id = '\(fixture.runID)'",
        at: JournalTestSupport.databaseURL(in: fixture.directory)
      ) == 2
    )
    try await fixture.journal.close()
  }

  private func makeJournal() async throws -> (
    directory: URL,
    journal: SQLiteAgentEventJournal,
    runID: AgentRunID
  ) {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: JournalTestSupport.configuration(in: directory)
    )
    return (directory, journal, AgentRunID())
  }
}
