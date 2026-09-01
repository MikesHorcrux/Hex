import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("Independent persistence terminal audit")
struct SQLiteJournalIndependentTerminalAuditTests {
  @Test
  func allowedToolRequiresStartThenExactlyOneFinishBeforeCompletion() async throws {
    let fixture = try await makeFixture(toolCallID: ToolCallID(rawValue: "allowed-tool"))
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    _ = try await fixture.journal.append(.runStarted, to: fixture.runID)
    _ = try await fixture.journal.append(
      .authorizationRequested(fixture.request),
      to: fixture.runID
    )
    _ = try await fixture.journal.append(
      .authorizationDecided(requestID: fixture.request.id, decision: .allow),
      to: fixture.runID
    )
    let prematureResult = ToolResult(
      toolCallID: fixture.toolCall.id,
      status: .failure,
      output: .null
    )
    do {
      _ = try await fixture.journal.append(.toolFinished(prematureResult), to: fixture.runID)
      Issue.record("An allowed tool finished without a durable start.")
    } catch is SQLiteAgentEventJournalError {
      // Expected rollback; the valid runtime order remains appendable.
    }

    _ = try await fixture.journal.append(.toolStarted(fixture.toolCall), to: fixture.runID)
    _ = try await fixture.journal.append(.toolFinished(prematureResult), to: fixture.runID)
    _ = try await fixture.journal.append(.runCompleted, to: fixture.runID)
    let records = try await fixture.journal.records(for: fixture.runID, after: nil, limit: 10)
    #expect(records.count == 6)
    try await fixture.journal.close()
  }

  @Test
  func deniedToolRequiresOneFailureFinishWithoutStarting() async throws {
    let fixture = try await makeFixture(toolCallID: ToolCallID(rawValue: "denied-tool"))
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    _ = try await fixture.journal.append(.runStarted, to: fixture.runID)
    _ = try await fixture.journal.append(
      .authorizationRequested(fixture.request),
      to: fixture.runID
    )
    _ = try await fixture.journal.append(
      .authorizationDecided(
        requestID: fixture.request.id,
        decision: .deny(reason: "not approved")
      ),
      to: fixture.runID
    )

    do {
      _ = try await fixture.journal.append(.toolStarted(fixture.toolCall), to: fixture.runID)
      Issue.record("A denied tool received a durable start.")
    } catch is SQLiteAgentEventJournalError {
      // Expected rollback.
    }
    do {
      _ = try await fixture.journal.append(
        .toolFinished(
          ToolResult(toolCallID: fixture.toolCall.id, status: .success, output: .null)
        ),
        to: fixture.runID
      )
      Issue.record("A denied tool recorded a successful outcome.")
    } catch is SQLiteAgentEventJournalError {
      // Expected rollback.
    }

    _ = try await fixture.journal.append(
      .toolFinished(
        ToolResult(toolCallID: fixture.toolCall.id, status: .failure, output: .null)
      ),
      to: fixture.runID
    )
    _ = try await fixture.journal.append(.runCompleted, to: fixture.runID)
    let records = try await fixture.journal.records(for: fixture.runID, after: nil, limit: 10)
    #expect(records.count == 5)
    try await fixture.journal.close()
  }

  @Test
  func duplicateAuthorizationCorrelationIsRejectedBeforeMutation() async throws {
    let fixture = try await makeFixture(toolCallID: ToolCallID(rawValue: "duplicate-correlation"))
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    _ = try await fixture.journal.append(.runStarted, to: fixture.runID)
    _ = try await fixture.journal.append(
      .authorizationRequested(fixture.request),
      to: fixture.runID
    )
    let duplicate = AuthorizationRequest(
      runID: fixture.runID,
      toolCallID: fixture.toolCall.id,
      capability: CapabilityID(rawValue: "audit"),
      operation: "inspect-again",
      explanation: "Duplicate tool correlation fixture"
    )
    do {
      _ = try await fixture.journal.append(.authorizationRequested(duplicate), to: fixture.runID)
      Issue.record("Two authorization requests correlated the same tool call.")
    } catch is SQLiteAgentEventJournalError {
      // Expected rollback.
    }
    let records = try await fixture.journal.records(for: fixture.runID, after: nil, limit: 10)
    #expect(records.count == 2)
    try await fixture.journal.close()
  }

  @Test
  func failedAndCancelledRunsPermitIncompleteAuthorizedTools() async throws {
    let terminals = [
      SQLiteInterruptedRunTerminal.event,
      AgentEvent.runCancelled,
    ]
    for (index, terminal) in terminals.enumerated() {
      let fixture = try await makeFixture(
        toolCallID: ToolCallID(rawValue: "incomplete-terminal-\(index)")
      )
      defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
      _ = try await fixture.journal.append(.runStarted, to: fixture.runID)
      _ = try await fixture.journal.append(
        .authorizationRequested(fixture.request),
        to: fixture.runID
      )
      _ = try await fixture.journal.append(
        .authorizationDecided(requestID: fixture.request.id, decision: .allow),
        to: fixture.runID
      )
      _ = try await fixture.journal.append(terminal, to: fixture.runID)
      try await fixture.journal.close()
    }
  }

  @Test(arguments: [AuthorizationDecision.allow, .deny(reason: "not approved")])
  func runCompletedRejectsAnAuthorizedToolWithoutDurableOutcome(
    decision: AuthorizationDecision
  ) async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
    )
    let runID = AgentRunID()
    let toolCallID = ToolCallID(rawValue: "authorized-without-outcome")
    let request = AuthorizationRequest(
      runID: runID,
      toolCallID: toolCallID,
      capability: CapabilityID(rawValue: "audit"),
      operation: "inspect",
      explanation: "Independent lifecycle fixture"
    )
    _ = try await journal.append(.runStarted, to: runID)
    _ = try await journal.append(.authorizationRequested(request), to: runID)
    _ = try await journal.append(
      .authorizationDecided(requestID: request.id, decision: decision),
      to: runID
    )

    do {
      _ = try await journal.append(.runCompleted, to: runID)
      Issue.record("runCompleted committed before the authorized tool had a durable outcome.")
    } catch is SQLiteAgentEventJournalError {
      // Expected: every authorization-correlated tool needs a durable outcome before success.
    }

    let records = try await journal.records(for: runID, after: nil, limit: 10)
    #expect(records.count == 3)
    try await journal.close()
  }

  private func makeFixture(
    toolCallID: ToolCallID
  ) async throws -> (
    directory: URL,
    journal: SQLiteAgentEventJournal,
    runID: AgentRunID,
    request: AuthorizationRequest,
    toolCall: ToolCall
  ) {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: JournalTestSupport.configuration(in: directory)
    )
    let runID = AgentRunID()
    return (
      directory,
      journal,
      runID,
      AuthorizationRequest(
        runID: runID,
        toolCallID: toolCallID,
        capability: CapabilityID(rawValue: "audit"),
        operation: "inspect",
        explanation: "Authorization-correlated tool fixture"
      ),
      ToolCall(id: toolCallID, name: "inspect", arguments: [:])
    )
  }
}
