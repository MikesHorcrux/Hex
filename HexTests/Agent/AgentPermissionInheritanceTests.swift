import Foundation
import HexCore
import HexIPC
import Testing

@testable import Hex

@Suite("Conversation permission inheritance")
struct AgentPermissionInheritanceTests {
  @Test @MainActor
  func resetRoundTripsNilWithoutChangingModelEffortOrOtherConversation() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("HexPermissionInheritance-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("conversations.json")
    let store = try AgentConversationStore(fileURL: file)
    let first = AgentConversation(
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      composerSelection:
        AgentComposerSelection(
          modelID: "selected-model", effort: .high, authorizationMode: .fullAccess))
    let other = AgentConversation(
      createdAt: Date(timeIntervalSince1970: 1_700_000_001),
      composerSelection:
        AgentComposerSelection(
          modelID: "other-model", effort: .low, authorizationMode: .askEveryTime))
    try await store.save(
      AgentConversationArchive(selectedConversationID: first.id, conversations: [first, other]))
    let model = AgentWorkspaceModel(
      client: PreviewHexAgentClient(), conversationStore: store,
      requiresConversationPersistence: true, defaultAuthorizationMode: .approveForMe)
    await model.restoreConversationHistory()
    #expect(model.hasComposerAuthorizationOverride)
    model.useSavedComposerAuthorizationMode()
    #expect(!model.hasComposerAuthorizationOverride)
    #expect(model.selectedComposerAuthorizationMode == .approveForMe)
    #expect(model.rememberedComposerModelID == "selected-model")
    #expect(model.composerEffort == .high)
    await model.conversationPersistenceTask?.value
    #expect(model.conversationSaveError == nil)
    let reopened = try AgentConversationStore(fileURL: file)
    let saved = try #require(try await reopened.load())
    #expect(
      saved.conversations.first { $0.id == first.id }?.composerSelection
        == AgentComposerSelection(modelID: "selected-model", effort: .high, authorizationMode: nil))
    #expect(saved.conversations.first { $0.id == other.id } == other)
    let restored = AgentWorkspaceModel(
      client: PreviewHexAgentClient(), conversationStore: reopened,
      requiresConversationPersistence: true, defaultAuthorizationMode: .askEveryTime)
    await restored.restoreConversationHistory()
    #expect(!restored.hasComposerAuthorizationOverride)
    #expect(restored.selectedComposerAuthorizationMode == .askEveryTime)
    restored.defaultAuthorizationMode = .fullAccess
    #expect(restored.selectedComposerAuthorizationMode == .fullAccess)
    #expect(restored.rememberedComposerModelID == "selected-model")
    #expect(restored.composerEffort == .high)
  }

  @Test @MainActor
  func resetCannotRewritePinnedAuthorityOrBypassFailedSaving() {
    let model = AgentWorkspaceModel(
      client: PreviewHexAgentClient(), defaultAuthorizationMode: .askEveryTime)
    model.selectedComposerAuthorizationMode = .fullAccess
    let conversations = model.conversations
    let request = GatewayStartRunRequest(
      runID: AgentRunID(), modelID: ModelID(rawValue: "preview"),
      initialMessages: [], authorizationMode: .fullAccess)
    model.currentRunRequest = request
    model.runState = .running
    model.useSavedComposerAuthorizationMode()
    #expect(model.hasComposerAuthorizationOverride)
    #expect(model.currentRunRequest == request)
    #expect(model.conversations == conversations)
    model.runState = .failed
    model.needsRunRecovery = true
    model.useSavedComposerAuthorizationMode()
    #expect(model.hasComposerAuthorizationOverride)
    #expect(model.currentRunRequest == request)
    #expect(model.conversations == conversations)
    model.needsRunRecovery = false
    model.conversationSaveError = "Previous archive save failed."
    model.useSavedComposerAuthorizationMode()
    #expect(model.hasComposerAuthorizationOverride)
    #expect(model.conversations == conversations)
    #expect(model.currentRunRequest == request)
  }

  @Test @MainActor
  func requiredButUnavailableArchiveCannotAcceptReset() {
    let model = AgentWorkspaceModel(
      client: PreviewHexAgentClient(), requiresConversationPersistence: true,
      defaultAuthorizationMode: .askEveryTime)
    model.rememberedComposerAuthorizationMode = .approveForMe
    model.useSavedComposerAuthorizationMode()
    #expect(model.hasComposerAuthorizationOverride)
    #expect(model.selectedComposerAuthorizationMode == .approveForMe)
    #expect(model.conversations.isEmpty)
    #expect(model.conversationPersistenceTask == nil)
  }
}
