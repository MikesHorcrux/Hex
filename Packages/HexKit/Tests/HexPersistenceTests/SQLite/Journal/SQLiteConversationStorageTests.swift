import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("Resident SQLite conversation storage")
struct SQLiteConversationStorageTests {
  @Test func maximumRecordsAndCheckpointsTravelSeparatelyWithoutReplacingSavedContext() async throws
  {
    let root = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(root) }
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: .init(
        databaseURL: JournalTestSupport.databaseURL(in: root), integrityPolicy: .incremental))
    let payload = Data(
      ("\"" + String(repeating: "x", count: ConversationStorageRequest.maximumPayloadBytes - 2)
        + "\"").utf8)
    var value = document()
    value.state = payload
    _ = try await journal.conversationStorage(.write(.init(document: value, entries: [])))
    value.revision = 1
    value.state = Data()
    let entry = ConversationStorageEntry(id: "large", kind: .message, payload: payload)
    let write = ConversationStorageWrite(
      document: value, entries: [entry], updatesCheckpoint: false)
    #expect(
      try JSONEncoder().encode(write).count < ConversationStorageRequest.maximumEncodedWriteBytes)
    _ = try await journal.conversationStorage(.write(write))
    #expect(
      try await journal.conversationStorage(.read(value.id)).documents.first?.state == payload)
    let page = try await journal.conversationStorage(
      .entries(value.id, kind: .message, before: nil, limit: 100, revision: 2))
    #expect(page.entries.first?.payload == payload)
    try await journal.close()
  }

  @Test func writesAreAtomicRevisionCheckedAndRetryable() async throws {
    let root = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(root) }
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: .init(
        databaseURL: JournalTestSupport.databaseURL(in: root), integrityPolicy: .incremental))
    var document = document()
    let entry = ConversationStorageEntry(
      id: "message:one", kind: .message,
      payload: Data(#"{"text":"original"}"#.utf8))
    let write = ConversationStorageWrite(document: document, entries: [entry])
    let first = try await journal.conversationStorage(.write(write))
    #expect(first.receipt?.revision == 1)
    #expect(try await journal.conversationStorage(.write(write)).receipt == first.receipt)
    await #expect(throws: ConversationStorageFailure.revisionConflict) {
      try await journal.conversationStorage(.write(.init(document: document, entries: [])))
    }
    document.revision = 1
    document.title = "must roll back"
    let changed = ConversationStorageEntry(
      id: entry.id, kind: .message,
      payload: Data(#"{"text":"replacement"}"#.utf8))
    await #expect(throws: ConversationStorageFailure.immutableEntry) {
      try await journal.conversationStorage(.write(.init(document: document, entries: [changed])))
    }
    let restored = try #require(
      await journal.conversationStorage(.read(document.id)).documents.first)
    #expect(restored.revision == 1)
    #expect(restored.title == "Conversation")
    try await journal.close()
  }

  @Test func migrationRemainsHiddenUntilVerifiedPublication() async throws {
    let root = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(root) }
    let configuration = SQLiteAgentEventJournalConfiguration(
      databaseURL: JournalTestSupport.databaseURL(in: root), integrityPolicy: .incremental)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let document = document()
    _ = try await journal.conversationStorage(
      .write(
        .init(
          document: document,
          entries: [], importID: "source-fingerprint")))
    #expect(try await journal.conversationStorage(.list(.init())).documents.isEmpty)
    try await journal.close()
    let reopened = try await SQLiteAgentEventJournal.open(configuration: configuration)
    #expect(try await reopened.conversationStorage(.list(.init())).documents.isEmpty)
    await #expect(throws: ConversationStorageFailure.revisionConflict) {
      try await reopened.conversationStorage(
        .publishImport(
          "source-fingerprint",
          documents: [.init(id: document.id, revision: 2)], selected: document.id))
    }
    _ = try await reopened.conversationStorage(
      .publishImport(
        "source-fingerprint",
        documents: [.init(id: document.id, revision: 1)], selected: document.id))
    #expect(try await reopened.conversationStorage(.list(.init())).documents.count == 1)
    #expect(try await reopened.conversationStorage(.status).selected == document.id)
    try await reopened.close()
  }

  @Test func pagesCrossOldConversationAndTranscriptCeilingsWithoutLoadingPayloadsInLists()
    async throws
  {
    let root = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(root) }
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: .init(
        databaseURL: JournalTestSupport.databaseURL(in: root), integrityPolicy: .incremental))
    var main = document()
    for page in 0..<12 {
      let entries = (0..<100).map { offset in
        let number = page * 100 + offset
        return ConversationStorageEntry(
          id: "display:\(number)", kind: .display,
          payload: Data("{\"number\":\(number)}".utf8), searchText: "marker \(number)")
      }
      _ = try await journal.conversationStorage(.write(.init(document: main, entries: entries)))
      main.revision += 1
    }
    for _ in 0..<70 {
      _ = try await journal.conversationStorage(.write(.init(document: document(), entries: [])))
    }
    let first = try await journal.conversationStorage(.list(.init(limit: 50)))
    #expect(first.documents.count == 50)
    #expect(first.documents.allSatisfy { $0.state.isEmpty })
    let second = try await journal.conversationStorage(.list(.init(after: first.next)))
    #expect(second.documents.count == 21)
    #expect(Set((first.documents + second.documents).map(\.id)).count == 71)
    var before: Int64?
    var seen = Set<String>()
    repeat {
      let page = try await journal.conversationStorage(
        .entries(
          main.id, kind: .display,
          before: before, limit: 73, revision: main.revision))
      #expect(page.entries.count <= 73)
      for entry in page.entries { #expect(seen.insert(entry.id).inserted) }
      before = page.before
    } while before != nil
    #expect(seen.count == 1_200)
    let search = try await journal.conversationStorage(.list(.init(search: "marker 1199")))
    #expect(search.documents.map(\.id) == [main.id])
    try await journal.close()
  }

  @Test func incrementalRecoveryDoesNotTreatLifetimeHistoryAsARecoveryBudget() async throws {
    let root = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(root) }
    let configuration = SQLiteAgentEventJournalConfiguration(
      databaseURL: JournalTestSupport.databaseURL(in: root), integrityPolicy: .incremental,
      maximumRecoveryRunCount: 2, maximumRecoveryRecordCount: 3,
      maximumRecoveryBytes: 2_048, maximumDatabaseBytes: 1_024)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    for _ in 0..<50 {
      let run = AgentRunID()
      _ = try await journal.append(.runStarted, to: run)
      _ = try await journal.append(.runCompleted, to: run)
    }
    let interrupted = AgentRunID()
    _ = try await journal.append(.runStarted, to: interrupted)
    let call = ToolCall(id: .init(rawValue: "pending-tool"), name: "test", arguments: [:])
    _ = try await journal.append(.toolStarted(call), to: interrupted)
    for _ in 0..<20 {
      _ = try await journal.append(.inferenceEvent(.textDelta("evidence")), to: interrupted)
    }
    try await journal.close()
    let reopened = try await SQLiteAgentEventJournal.open(configuration: configuration)
    #expect(await reopened.recoveredRuns.map(\.runID) == [interrupted])
    #expect(await reopened.recoveredRuns.first?.unresolvedToolCallIDs == [call.id])
    let snapshot = try #require(await reopened.runSnapshot(for: interrupted))
    #expect(snapshot.latestSequence == 23)
    #expect(snapshot.terminalRecord != nil)
    #expect(try await reopened.records(for: interrupted, after: 20, limit: 3).count == 3)
    try await reopened.close()
    let again = try await SQLiteAgentEventJournal.open(configuration: configuration)
    #expect(await again.recoveredRuns.isEmpty)
    try await again.close()
  }

  private func document() -> ConversationStorageDocument {
    .init(
      id: UUID(), title: "Conversation", createdAt: Date(timeIntervalSince1970: 100),
      updatedAt: Date(timeIntervalSince1970: 200), state: Data(#"{"version":1}"#.utf8))
  }
}
