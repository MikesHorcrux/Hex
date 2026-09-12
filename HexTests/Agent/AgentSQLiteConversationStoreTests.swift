import Foundation
import HexCore
import HexPersistence
import Testing

@testable import Hex

@Suite("SQLite app history migration and working context")
struct AgentSQLiteConversationStoreTests {
  @Test func aListRefreshCannotLetAStaleWorkingCopyOverwriteANewerCheckpoint() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: .init(
        databaseURL: root.appendingPathComponent("events.sqlite"), integrityPolicy: .incremental))
    let first = AgentSQLiteConversationStore(storage: journal, legacy: nil)
    let second = AgentSQLiteConversationStore(storage: journal, legacy: nil)
    var original = AgentConversation(history: .init(contextBase: []))
    try await first.saveChanges([original], selected: original.id)
    var stale = try await second.readConversation(original.id)
    original.title = "Newer saved work"
    try await first.saveChanges([original], selected: original.id)
    _ = try await second.listConversations(.init())
    stale.title = "Stale replacement"
    await #expect(throws: ConversationStorageFailure.revisionConflict) {
      try await second.saveChanges([stale], selected: stale.id)
    }
    #expect(try await first.readConversation(original.id).title == "Newer saved work")
    try await journal.close()
  }

  @Test func largeLegacyArchiveMigratesExactlyAndLoadsOnlyTheCurrentPage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("conversations.json")
    let legacy = try AgentConversationStore(fileURL: file)
    let rows = (0..<110).map {
      ConversationItem(role: .event, text: "Row \($0) " + String(repeating: "x", count: 45_000))
    }
    let goal = Message(role: .user, content: [.text("Remember this goal")])
    let answer = Message(role: .assistant, content: [.text("Remembered")])
    let conversation = AgentConversation(
      transcript: rows,
      history: .init(exchanges: [
        .init(runID: AgentRunID(), messages: [goal, answer], outcome: .completed)
      ]))
    try await legacy.save(
      .init(selectedConversationID: conversation.id, conversations: [conversation]))
    let source = try Data(contentsOf: file)
    #expect(source.count > 4 * 1_024 * 1_024)
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: .init(
        databaseURL: root.appendingPathComponent("events.sqlite"), integrityPolicy: .incremental))
    let store = AgentSQLiteConversationStore(storage: journal, legacy: legacy)
    let archive = try #require(try await store.load())
    let loaded = try #require(archive.conversations.first)
    #expect(loaded.transcript.count < conversation.transcript.count)
    #expect(loaded.transcript.last == conversation.transcript.last)
    #expect(loaded.contextMessages() == [goal, answer])
    #expect(try Data(contentsOf: file) == source)
    let page = try await store.listConversations(.init())
    #expect(page.conversations.first?.history == nil)
    #expect(page.conversations.first?.transcript.isEmpty == true)
    let reopen = AgentSQLiteConversationStore(storage: journal, legacy: legacy)
    let again = try #require(try await reopen.load())
    #expect(again.conversations.first?.contextMessages() == [goal, answer])
    #expect(try Data(contentsOf: file) == source)
    try await journal.close()
  }

  @Test func workingCheckpointContinuesActiveCompactionAndRetainsRetryBase() throws {
    let old = [
      Message(role: .user, content: [.text("Earlier task")]),
      Message(role: .assistant, content: [.text("Earlier result")]),
    ]
    let run = AgentRunID()
    let goal = Message(role: .user, content: [.text("Current goal")])
    let first = batch()
    let initial = try AgentContextCompaction(
      ownerRunID: run, sourceMessageIDs: old.map(\.id),
      summaryText: "Earlier summary", providerID: .init(rawValue: "test"),
      modelID: .init(rawValue: "model"),
      estimatedTokensBefore: 1_000, estimatedTokensAfter: 100)
    let active = try compaction(run, source: first)
    let original = AgentConversationHistory(
      legacyMessages: old,
      exchanges: [.init(runID: run, messages: [goal] + first)], compactions: [initial, active])
    var working = try AgentConversationContextProjection.workingHistory(in: original)
    #expect(
      try AgentConversationContextProjection.messages(in: working)
        == AgentConversationContextProjection.messages(in: original))
    let next = batch()
    working.exchanges[0].messages += next
    let nextCompaction = try compaction(run, source: [active.summaryMessage] + next)
    working.compactions.append(nextCompaction)
    var ids = Set<AgentRunID>()
    try AgentConversationHistoryValidator.validate(working, runIDs: &ids)
    let second = try AgentConversationContextProjection.workingHistory(in: working)
    #expect(
      try AgentConversationContextProjection.messages(in: second)
        == [initial.summaryMessage, goal, nextCompaction.summaryMessage])

    // A tool-free failed attempt may be retried with the original pre-compaction request.
    let failed = AgentConversationHistory(
      legacyMessages: old,
      exchanges: [.init(runID: run, messages: [goal], outcome: .failed)], compactions: [initial])
    var retry = try AgentConversationContextProjection.workingHistory(in: failed)
    retry.exchanges.append(.init(runID: AgentRunID(), messages: [goal], retryOfRunID: run))
    #expect(try AgentConversationContextProjection.messages(in: retry) == old + [goal])
  }

  private func batch() -> [Message] {
    let call = ToolCall(name: "echo", arguments: [:])
    return [
      Message(role: .assistant, content: [.toolCall(call)]),
      Message(
        role: .tool,
        content: [
          .toolResult(
            .init(
              toolCallID: call.id,
              status: .success, output: .string("evidence")))
        ]),
    ]
  }

  private func compaction(_ run: AgentRunID, source: [Message]) throws -> AgentContextCompaction {
    try AgentContextCompaction(
      ownerRunID: run, sourceMessageIDs: source.map(\.id),
      summaryText: "Tool summary", providerID: .init(rawValue: "test"),
      modelID: .init(rawValue: "model"),
      estimatedTokensBefore: 1_000, estimatedTokensAfter: 100, boundary: .completedToolBatch)
  }
}
