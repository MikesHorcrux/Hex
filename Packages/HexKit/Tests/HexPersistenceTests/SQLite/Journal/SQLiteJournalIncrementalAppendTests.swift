import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("SQLite journal incremental append integrity")
struct SQLiteJournalIncrementalAppendTests {
  @Test
  func interleavedRunsAndCheckpointPreserveAccountingAcrossRejectedCompletion() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let firstRun = AgentRunID()
    let secondRun = AgentRunID()
    _ = try await journal.append(.runStarted, to: firstRun)
    _ = try await journal.append(.runStarted, to: secondRun)
    let tool = ToolCall(id: ToolCallID(rawValue: "test-tool"), name: "test", arguments: [:])
    _ = try await journal.append(.toolStarted(tool), to: firstRun)
    _ = try await journal.writeCheckpoint(for: secondRun, through: 1, snapshot: .null)

    await #expect(throws: SQLiteAgentEventJournalError.self) {
      try await journal.append(.runCompleted, to: firstRun)
    }
    let finished = try await journal.append(
      .toolFinished(ToolResult(toolCallID: tool.id, status: .success, output: .null)),
      to: firstRun
    )
    #expect(finished.sequence == 3)
    _ = try await journal.append(.runCompleted, to: firstRun)
    _ = try await journal.append(.inferenceEvent(.textDelta("still streaming")), to: secondRun)
    try await expectAccountingMatchesDurableJournal(journal)
    _ = try await journal.append(.runCompleted, to: secondRun)
    try await expectAccountingMatchesDurableJournal(journal)
    #expect(await journal.activeRunStates.isEmpty)
    try await journal.close()

    let reopened = try await SQLiteAgentEventJournal.open(configuration: configuration)
    #expect(await reopened.recoveredRuns.isEmpty)
    #expect(try await reopened.records(for: firstRun, after: nil, limit: 4).count == 4)
    #expect(try await reopened.records(for: secondRun, after: nil, limit: 3).count == 3)
    #expect(try await reopened.latestCheckpoint(for: secondRun)?.snapshot == .null)
    try await reopened.close()
  }

  private func expectAccountingMatchesDurableJournal(
    _ journal: isolated SQLiteAgentEventJournal
  ) throws {
    let actual = try journal.validateWholeJournalIntegrity(connection: journal.requireConnection())
    #expect(journal.integrityUsage == actual)
  }
}
