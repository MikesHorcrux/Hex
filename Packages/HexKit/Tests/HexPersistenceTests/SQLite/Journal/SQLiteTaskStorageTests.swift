import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("SQLite durable task storage")
struct SQLiteTaskStorageTests {
  @Test
  func revisionConflictCannotOverwriteNewerControlAfterReopen() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let input = AgentTaskRecord(
      id: UUID(), title: "preserve", request: Data([1]), admissionHash: Data([2]))
    let admitted = try await journal.saveTask(input)
    var paused = admitted
    paused.phase = .paused
    let saved = try await journal.saveTask(paused)
    await #expect(throws: AgentTaskStorageError.self) { _ = try await journal.saveTask(admitted) }
    try await journal.close()
    let reopened = try await SQLiteAgentEventJournal.open(configuration: configuration)
    #expect(try await reopened.readTask(input.id) == saved)
    #expect(
      try await reopened.listTasks(after: nil, limit: 20, unfinishedOnly: true).first?.request
        .isEmpty == true)
    try await reopened.close()
  }

  @Test
  func versionFourMigratesTasksWithoutChangingOriginalEvents() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    let start = try await journal.append(.runStarted, to: runID)
    let end = try await journal.append(.runCompleted, to: runID)
    try await journal.close()
    try JournalTestSupport.execute(
      """
      DROP TABLE conversation_timeline;
      DROP TABLE conversation_tasks;
      DROP TABLE agent_task_effects;
      DROP TABLE agent_task_attempts;
      DROP TABLE agent_tasks;
      PRAGMA user_version = 4;
      """, at: configuration.databaseURL)
    let reopened = try await SQLiteAgentEventJournal.open(configuration: configuration)
    #expect(try await reopened.records(for: runID, after: nil, limit: 10) == [start, end])
    #expect(try await reopened.listTasks(after: nil, limit: 20, unfinishedOnly: false).isEmpty)
    try await reopened.close()
    #expect(try JournalTestSupport.userVersion(at: configuration.databaseURL) == 6)
  }
}
