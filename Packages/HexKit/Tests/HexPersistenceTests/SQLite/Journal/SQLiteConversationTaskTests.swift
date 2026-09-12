import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("Conversation-owned durable work")
struct SQLiteConversationTaskTests {
  @Test
  func admissionLinksAndInputCommitTogetherAndRejectStaleParents() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let config = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: config)
    let parent = UUID()
    var first = AgentTaskRecord(
      id: UUID(), title: "one chat", request: Data(), admissionHash: Data([1]))
    first.conversationID = parent
    first.userMessage = Message(role: .user, content: [.text("Remember COBALT-42")])
    let saved = try await journal.saveTask(first)
    var second = AgentTaskRecord(
      id: UUID(), title: "follow-up", request: Data(), admissionHash: Data([2]))
    second.conversationID = parent
    second.userMessage = Message(role: .user, content: [.text("What was it?")])
    await #expect(throws: AgentTaskStorageError.revisionConflict) {
      _ = try await journal.saveTask(second)
    }
    #expect(try await journal.readTask(second.id) == nil)
    #expect(
      try await journal.conversationTimeline(parent, before: nil, limit: 40).entries.count == 1)
    second.predecessorID = saved.id
    let next = try await journal.saveTask(second)
    try await journal.close()
    let reopened = try await SQLiteAgentEventJournal.open(configuration: config)
    #expect(
      try await reopened.conversationTasks(parent, before: nil, limit: 20).map(\.id) == [
        next.id, saved.id,
      ])
    #expect(try await reopened.conversationStorage(.list(.init())).documents.count == 1)
    #expect(
      try await reopened.conversationTasks(parent, before: nil, limit: 20)
        .allSatisfy { $0.userMessage == nil && $0.request.isEmpty })
    #expect(try await reopened.readTask(first.id)?.userMessage == first.userMessage)
    #expect(
      try await reopened.conversationTimeline(parent, before: nil, limit: 40).entries.map(\.id)
        == [first.userMessage?.id.rawValue, second.userMessage?.id.rawValue].compactMap { $0 })
    try await reopened.close()
  }

  @Test
  func activeControlTargetIsIndependentOfRecentPageAndSteeringIsIdempotent() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: JournalTestSupport.configuration(in: directory))
    let parent = UUID()
    var previous: UUID?
    var first: AgentTaskRecord?
    for i in 0..<25 {
      var record = AgentTaskRecord(
        id: UUID(), title: "request \(i)", request: Data(), admissionHash: Data([1]))
      record.conversationID = parent
      record.predecessorID = previous
      record.phase = i == 0 ? .paused : .queued
      let saved = try await journal.saveTask(record)
      previous = saved.id
      if first == nil { first = saved }
    }
    #expect(try await journal.conversationTasks(parent, before: nil, limit: 20).count == 20)
    #expect(try await journal.activeConversationTask(parent)?.id == first?.id)
    var paused = try #require(first)
    let instruction = AgentTaskRecord.Instruction(id: UUID(), text: "Keep this once")
    paused.instructions.append(instruction)
    let saved = try await journal.saveTask(paused)
    _ = try await journal.saveTask(saved)
    #expect(
      try await journal.conversationTimeline(parent, before: nil, limit: 40).entries.map(\.id) == [
        instruction.id
      ])
    try await journal.close()
  }
}
