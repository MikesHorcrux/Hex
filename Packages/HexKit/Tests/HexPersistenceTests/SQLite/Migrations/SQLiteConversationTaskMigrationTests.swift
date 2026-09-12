import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("Conversation task migration")
struct SQLiteConversationTaskMigrationTests {
  @Test
  func versionFiveRetainsLegacyDocumentsAndOriginalRunReceipts() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let config = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: config)
    let oldID = UUID()
    let originalState = Data("{\"legacy\":true}".utf8)
    let document = ConversationStorageDocument(
      id: oldID, title: "Original chat",
      createdAt: Date(), updatedAt: Date(), state: originalState)
    _ = try await journal.conversationStorage(.write(.init(document: document, entries: [])))
    let runID = AgentRunID()
    var task = AgentTaskRecord(
      id: UUID(), title: "Recovered chat", request: Data(), admissionHash: Data([1]))
    task.runID = runID
    task.attemptCount = 1
    task = try await journal.saveTask(task)
    let first = try await journal.append(.runStarted, to: runID)
    let message = Message(role: .user, content: [.text("Original request")])
    let input = try await journal.append(.messageAppended(message), to: runID)
    let terminal = try await journal.append(.runCancelled, to: runID)
    try await journal.close()
    try JournalTestSupport.execute(
      """
      DROP TABLE process_segments;
      DROP TABLE process_operations;
      DROP TABLE process_sessions;
      DROP TABLE coding_patches;
      DROP TABLE coding_baselines;
      DROP TABLE conversation_timeline;
      DROP TABLE conversation_tasks;
      DELETE FROM conversation_documents WHERE id = '\(task.id.uuidString)';
      PRAGMA user_version = 5;
      """, at: config.databaseURL)
    let reopened = try await SQLiteAgentEventJournal.open(configuration: config)
    #expect(
      try await reopened.conversationStorage(.read(oldID)).documents.first?.state == originalState)
    #expect(try await reopened.readTask(task.id)?.conversationID == task.id)
    let timeline = try await reopened.conversationTimeline(task.id, before: nil, limit: 40)
    #expect(timeline.entries.first?.id == message.id.rawValue)
    #expect(timeline.entries.map(\.content) == [.message(message), .notice("Work cancelled")])
    #expect(
      try await reopened.records(for: runID, after: nil, limit: 10) == [first, input, terminal])
    try await reopened.close()
    #expect(try JournalTestSupport.userVersion(at: config.databaseURL) == 7)
  }
}
