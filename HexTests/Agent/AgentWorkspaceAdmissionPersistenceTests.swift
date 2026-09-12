import Foundation
import Testing

@testable import Hex

@Suite("Agent workspace admission persistence")
struct AgentWorkspaceAdmissionPersistenceTests {
  @Test @MainActor
  func liveStorageRequirementCannotSilentlyBecomeAnEphemeralSession() async throws {
    let model = AgentWorkspaceModel(
      client: PreviewHexAgentClient(), conversationStore: nil,
      requiresConversationPersistence: true)
    await model.restoreConversationHistory()
    await model.connect()
    model.draft = "Keep my work"
    model.send()
    #expect(model.currentRunID == nil)
    #expect(model.draft == "Keep my work")
    #expect(model.conversationSaveError != nil)
  }

  @Test @MainActor
  func failedSaveDoesNotDispatchOrConsumeDraft() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("HexAdmission-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("conversations.json")
    let store = try AgentConversationStore(fileURL: fileURL)
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient(), conversationStore: store)
    await model.restoreConversationHistory()
    await model.connect()
    // Simulate an unavailable archive destination after a successful load; no live data is used.
    try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
    model.draft = "Do not send an unsaved request"
    model.send()
    for _ in 0..<100 where model.currentInvocationID == nil && model.isRunActive {
      try await Task.sleep(for: .milliseconds(10))
    }
    let wasAdmitted = model.currentInvocationID != nil
    model.runTask?.cancel()
    await model.runTask?.value
    await model.conversationPersistenceTask?.value

    #expect(!wasAdmitted)
    #expect(model.draft == "Do not send an unsaved request")
    #expect(model.transcript.isEmpty)
    #expect(model.errorMessage != nil)
  }
}
