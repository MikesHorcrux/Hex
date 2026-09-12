import Foundation
import HexCore
import HexIPC
import Testing

@testable import Hex

@Suite("Conversation organization archive metadata")
struct AgentConversationOrganizationStoreTests {
  @Test
  func explicitDefaultNameAndArchiveMetadataSurviveReopenWithNativeHistory() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("conversations.json")
    let store = try AgentConversationStore(fileURL: url)
    let user = Message(role: .user, content: [.text("Original request")])
    let runID = AgentRunID()
    let checkpoint = AgentConversationRunCheckpoint(
      request: GatewayStartRunRequest(
        runID: runID, modelID: ModelID(rawValue: "fixture"), initialMessages: [user]))
    let created = Date(timeIntervalSinceReferenceDate: 100)
    let archived = Date(timeIntervalSinceReferenceDate: 200)
    let conversation = AgentConversation(
      title: AgentConversation.defaultTitle, createdAt: created, updatedAt: archived,
      transcript: [ConversationItem(role: .user, text: "Original request")],
      history: AgentConversationHistory(exchanges: [
        AgentConversationExchange(runID: runID, messages: [user])
      ]), pendingRun: checkpoint, archivedAt: archived, isTitleExplicit: true)
    let archive = AgentConversationArchive(
      selectedConversationID: conversation.id, conversations: [conversation])
    try await store.save(archive)

    let reopened = try AgentConversationStore(fileURL: url)
    let loaded = try #require(try await reopened.load())
    #expect(loaded == archive)
    var restored = try #require(loaded.conversations.first)
    restored.recordPrompt("A different automatic title")
    #expect(restored.title == AgentConversation.defaultTitle)
    #expect(restored.isArchived)
    #expect(restored.pendingRun == checkpoint)
    #expect(restored.history == conversation.history)
  }

  @Test
  func legacyCanonicalArchiveDoesNotAcquireOrganizationFieldsOrRewriteOnLoad() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("conversations.json")
    let conversation = AgentConversation(title: "Existing name")
    let archive = AgentConversationArchive(
      selectedConversationID: conversation.id, conversations: [conversation])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(archive)
    #expect(!String(decoding: data, as: UTF8.self).contains("archivedAt"))
    #expect(!String(decoding: data, as: UTF8.self).contains("isTitleExplicit"))
    try data.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

    let store = try AgentConversationStore(fileURL: url)
    #expect(try await store.load() == archive)
    #expect(try Data(contentsOf: url) == data)
    #expect(!conversation.isArchived)
  }

  @Test(arguments: ["", " \t ", "Name\nOther", "Name\u{0000}", String(repeating: "é", count: 129)])
  func invalidExplicitNamesAreRejectedWithoutReplacingSavedData(_ title: String) async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("conversations.json")
    let store = try AgentConversationStore(fileURL: url)
    let original = AgentConversation()
    try await store.save(
      AgentConversationArchive(selectedConversationID: original.id, conversations: [original]))
    let bytes = try Data(contentsOf: url)
    var invalid = original
    invalid.title = title
    invalid.isTitleExplicit = true

    await #expect(throws: AgentConversationStoreError.self) {
      try await store.save(
        AgentConversationArchive(selectedConversationID: original.id, conversations: [invalid]))
    }
    #expect(try Data(contentsOf: url) == bytes)
  }

  @Test
  func invalidArchiveTimestampIsRejected() throws {
    let created = Date(timeIntervalSinceReferenceDate: 100)
    var conversation = AgentConversation(createdAt: created)
    for archived in [
      Date(timeIntervalSinceReferenceDate: 99), Date(timeIntervalSinceReferenceDate: 101),
    ] {
      conversation.archivedAt = archived
      #expect(throws: AgentConversationStoreError.self) {
        try AgentConversationStore.validateForPersistence(
          AgentConversationArchive(
            selectedConversationID: conversation.id, conversations: [conversation]))
      }
    }
  }

  private nonisolated func directory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("hex-organization-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
  }
}
