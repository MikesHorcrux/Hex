import Foundation
import Testing

@testable import Hex

@Suite("Agent conversation persistence safety")
struct AgentConversationPersistenceSafetyTests {
  @Test @MainActor
  func failedRestoreCannotOverwriteUnreadableArchive() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("conversations.json")
    let original = Data("{unreadable history".utf8)
    try writePrivateData(original, to: fileURL)
    let store = try AgentConversationStore(fileURL: fileURL)
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient(), conversationStore: store)

    await model.restoreConversationHistory()
    model.newConversation()
    model.persistConversationArchive()
    await model.conversationPersistenceTask?.value

    #expect(try Data(contentsOf: fileURL) == original)
    #expect(model.errorMessage != nil)
  }

  @Test @MainActor
  func unreadableArchiveBlocksSendWithoutConsumingDraft() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("conversations.json")
    let original = Data("{unreadable history".utf8)
    try writePrivateData(original, to: fileURL)
    let store = try AgentConversationStore(fileURL: fileURL)
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient(), conversationStore: store)
    await model.restoreConversationHistory()
    await model.connect()
    model.draft = "Keep this request until history is safe"

    model.send()
    let draftWasPreserved = model.draft == "Keep this request until history is safe"
    let remainedIdle = model.runState == .idle
    model.runTask?.cancel()
    await model.runTask?.value
    await model.conversationPersistenceTask?.value

    #expect(draftWasPreserved)
    #expect(remainedIdle)
    #expect(try Data(contentsOf: fileURL) == original)
  }

  @Test @MainActor
  func promptAbovePersistenceLimitIsRejectedBeforeMutation() async {
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient(), conversationStore: nil)
    await model.connect()
    let prompt = String(repeating: "x", count: 64 * 1_024 + 1)
    model.draft = prompt

    model.send()
    let draftWasPreserved = model.draft == prompt
    let remainedIdle = model.runState == .idle
    let transcriptWasEmpty = model.transcript.isEmpty
    model.runTask?.cancel()
    await model.runTask?.value

    #expect(draftWasPreserved)
    #expect(remainedIdle)
    #expect(transcriptWasEmpty)
    #expect(AgentConversation.maximumPromptBytes <= AgentConversation.maximumPersistedTextBytes)
  }

  @Test @MainActor
  func conversationLimitRejectsNewConversationBeforeMutation() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AgentConversationStore(
      fileURL: directory.appendingPathComponent("conversations.json"))
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient(), conversationStore: store)
    await model.restoreConversationHistory()
    for _ in 0..<64 { model.newConversation() }
    await model.conversationPersistenceTask?.value
    let selectedID = model.selectedConversationID

    model.newConversation()
    await model.conversationPersistenceTask?.value

    #expect(model.conversations.count == 64)
    #expect(model.selectedConversationID == selectedID)
    #expect(model.errorMessage != nil)
    #expect(try await store.load()?.conversations.count == 64)
  }

  @Test @MainActor
  func transcriptLimitRejectsPromptWithoutConsumingDraft() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AgentConversationStore(
      fileURL: directory.appendingPathComponent("conversations.json"))
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient(), conversationStore: store)
    await model.restoreConversationHistory()
    await model.connect()
    model.newConversation()
    model.transcript = (0..<512).map { ConversationItem(role: .event, text: "Event \($0)") }
    model.persistConversationArchive()
    await model.conversationPersistenceTask?.value
    model.draft = "This belongs in a new conversation"

    model.send()
    let draftWasPreserved = model.draft == "This belongs in a new conversation"
    let transcriptCount = model.transcript.count
    model.runTask?.cancel()
    await model.runTask?.value

    #expect(draftWasPreserved)
    #expect(transcriptCount == 512)
    #expect(model.errorMessage != nil)
  }

  @Test @MainActor
  func oversizedGeneratedOutputDoesNotPoisonAnotherConversationSave() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AgentConversationStore(
      fileURL: directory.appendingPathComponent("conversations.json"))
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient(), conversationStore: store)
    await model.restoreConversationHistory()
    model.newConversation()
    let firstID = try #require(model.selectedConversationID)
    model.appendTool("A saved tool result")
    await model.conversationPersistenceTask?.value
    let oversized = String(repeating: "x", count: 64 * 1_024 + 1)
    model.appendTool(oversized)
    await model.conversationPersistenceTask?.value
    #expect(model.transcript.last?.text == oversized)
    #expect(model.errorMessage != nil)

    model.newConversation()
    let secondID = try #require(model.selectedConversationID)
    model.appendEvent("New conversation is saved")
    await model.conversationPersistenceTask?.value
    let archive = try #require(try await store.load())

    #expect(secondID != firstID)
    #expect(
      archive.conversations.first(where: { $0.id == secondID })?.transcript.last?.text
        == "New conversation is saved")
    #expect(
      archive.conversations.first(where: { $0.id == firstID })?.transcript.last?.text
        == "A saved tool result")
    model.selectConversation(firstID)
    #expect(model.transcript.last?.text == oversized)
    #expect(model.errorMessage != nil)
  }

  @Test @MainActor
  func archiveByteLimitRejectsPromptBeforeMutation() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AgentConversationStore(
      fileURL: directory.appendingPathComponent("conversations.json"), maximumBytes: 1_024)
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient(), conversationStore: store)
    await model.restoreConversationHistory()
    await model.connect()
    model.newConversation()
    await model.conversationPersistenceTask?.value
    let original = try #require(try await store.load())
    let prompt = String(repeating: "x", count: 1_024)
    model.draft = prompt

    model.send()
    let draftWasPreserved = model.draft == prompt
    let transcriptWasEmpty = model.transcript.isEmpty
    model.runTask?.cancel()
    await model.runTask?.value
    await model.conversationPersistenceTask?.value

    #expect(draftWasPreserved)
    #expect(transcriptWasEmpty)
    #expect(try await store.load() == original)
  }

  @Test @MainActor
  func deletingConversationFreesCapacityForAnotherSavedConversation() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AgentConversationStore(
      fileURL: directory.appendingPathComponent("conversations.json"))
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient(), conversationStore: store)
    await model.restoreConversationHistory()
    for _ in 0..<64 { model.newConversation() }
    await model.conversationPersistenceTask?.value
    let removedID = try #require(model.selectedConversationID)

    model.deleteConversation(removedID)
    model.newConversation()
    model.appendEvent("Saved after freeing capacity")
    await model.conversationPersistenceTask?.value
    let archive = try #require(try await store.load())

    #expect(model.conversations.count == 64)
    #expect(archive.conversations.count == 64)
    #expect(!archive.conversations.contains(where: { $0.id == removedID }))
    #expect(
      archive.conversations.first(where: { $0.id == model.selectedConversationID })?.transcript
        .last?.text == "Saved after freeing capacity")
    #expect(model.errorMessage == nil)
  }

  @Test @MainActor
  func deletionPersistsWhileSelectedConversationHasUnsavedOutput() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AgentConversationStore(
      fileURL: directory.appendingPathComponent("conversations.json"))
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient(), conversationStore: store)
    await model.restoreConversationHistory()
    model.newConversation()
    let removedID = try #require(model.selectedConversationID)
    model.newConversation()
    let retainedID = try #require(model.selectedConversationID)
    model.appendEvent("Last saved output")
    await model.conversationPersistenceTask?.value
    let oversized = String(repeating: "x", count: 64 * 1_024 + 1)
    model.appendTool(oversized)

    model.deleteConversation(removedID)
    await model.conversationPersistenceTask?.value
    let archive = try #require(try await store.load())

    #expect(model.transcript.last?.text == oversized)
    #expect(model.selectedConversationID == retainedID)
    #expect(archive.conversations.count == 1)
    #expect(archive.conversations.first?.transcript.last?.text == "Last saved output")
    #expect(model.errorMessage?.contains("only in memory") == true)
  }

  @Test @MainActor
  func deletionRejectsActiveRunAndFinalDeletionSavesEmptyArchive() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AgentConversationStore(
      fileURL: directory.appendingPathComponent("conversations.json"))
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient(), conversationStore: store)
    await model.restoreConversationHistory()
    model.newConversation()
    let removedID = try #require(model.selectedConversationID)
    model.runState = .running

    model.deleteConversation(removedID)
    #expect(model.conversations.count == 1)
    #expect(model.errorMessage != nil)
    model.runState = .idle
    model.deleteConversation(removedID)
    await model.conversationPersistenceTask?.value
    let archive = try #require(try await store.load())

    #expect(model.conversations.isEmpty)
    #expect(model.selectedConversationID == nil)
    #expect(model.transcript.isEmpty)
    #expect(archive.conversations.isEmpty)
    #expect(archive.selectedConversationID == nil)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("HexPersistenceSafety-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    return directory
  }

  private func writePrivateData(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
  }
}
