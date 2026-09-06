import Foundation
import HexCore
import HexIPC
import Testing

@testable import Hex

@Suite("Durable conversation organization")
struct AgentWorkspaceConversationOrganizationTests {
  @Test @MainActor
  func offSelectionRenameAndReversibleArchivePreserveHistoryArtifactsAndSelection() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AgentConversationStore(
      fileURL: root.appendingPathComponent("conversations.json"))
    let original = completedConversation()
    let selected = AgentConversation(title: "Stay here")
    try await store.save(
      AgentConversationArchive(
        selectedConversationID: selected.id, conversations: [selected, original]))
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient(), conversationStore: store)
    await model.restoreConversationHistory()

    #expect(await model.renameConversation(original.id, to: "  Research notes  "))
    #expect(await model.setConversationArchived(original.id, archived: true))
    #expect(model.selectedConversationID == selected.id)
    let archived = try #require(
      try await store.load()?.conversations.first { $0.id == original.id })
    #expect(archived.title == "Research notes")
    #expect(archived.isArchived)
    #expect(archived.history == original.history)
    #expect(archived.artifactInventory == original.artifactInventory)
    #expect(archived.transcript == original.transcript)

    let reopened = AgentWorkspaceModel(client: PreviewHexAgentClient(), conversationStore: store)
    await reopened.restoreConversationHistory()
    #expect(await reopened.setConversationArchived(original.id, archived: false))
    let restored = try #require(
      try await store.load()?.conversations.first { $0.id == original.id })
    #expect(!restored.isArchived)
    #expect(restored.title == "Research notes")
    #expect(restored.history == original.history)
    #expect(restored.artifactInventory == original.artifactInventory)
    #expect(reopened.selectedConversationID == selected.id)
  }

  @Test @MainActor
  func archivingSelectedConversationKeepsItReadableAndBlocksSendingUntilRestored() async throws {
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient())
    model.newConversation()
    let id = try #require(model.selectedConversationID)
    model.appendEvent("Keep the visible transcript")
    await model.connect()
    model.draft = "Keep my draft"
    #expect(await model.setConversationArchived(id, archived: true))
    #expect(model.selectedConversationID == id)
    #expect(model.transcript.last?.text == "Keep the visible transcript")
    #expect(!model.canSend)
    model.send()
    #expect(model.draft == "Keep my draft")
    #expect(model.errorMessage?.contains("Unarchive") == true)
    #expect(await model.setConversationArchived(id, archived: false))
    #expect(model.canSend)
  }

  @Test @MainActor
  func explicitDefaultNameIsNotReplacedByPromptNaming() async throws {
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient())
    model.newConversation()
    let id = try #require(model.selectedConversationID)
    #expect(await model.renameConversation(id, to: AgentConversation.defaultTitle))
    model.updateCurrentConversation(withPrompt: "Do not replace my chosen name")
    #expect(model.conversations.first?.title == AgentConversation.defaultTitle)
    #expect(model.conversations.first?.isTitleExplicit == true)
  }

  @Test @MainActor
  func invalidNamesAndBlockedStatesDoNotMutateConversations() async throws {
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient())
    model.newConversation()
    let id = try #require(model.selectedConversationID)
    let original = model.conversations
    for title in ["", " \t ", "Name\nOther", "Name\u{0000}", String(repeating: "é", count: 129)] {
      #expect(!(await model.renameConversation(id, to: title)))
      #expect(model.errorMessage != nil)
      #expect(model.conversations == original)
    }
    model.runState = .running
    #expect(!model.canOrganizeConversation(id))
    #expect(!(await model.renameConversation(id, to: "Blocked")))
    model.runState = .idle
    model.isRecoveringRun = true
    #expect(!(await model.setConversationArchived(id, archived: true)))
    model.isRecoveringRun = false
    model.conversationPersistenceState.restoreFailed = true
    #expect(!(await model.renameConversation(id, to: "Blocked restore")))
    #expect(model.conversations == original)
  }

  @Test @MainActor
  func unresolvedCheckpointCanBeRenamedButCannotBeHidden() async throws {
    let user = Message(role: .user, content: [.text("Pending request")])
    let runID = AgentRunID()
    let checkpoint = AgentConversationRunCheckpoint(
      request: GatewayStartRunRequest(
        runID: runID, modelID: ModelID(rawValue: "fixture"), initialMessages: [user]))
    let pending = AgentConversation(
      transcript: [ConversationItem(role: .user, text: "Pending request")],
      history: AgentConversationHistory(exchanges: [
        AgentConversationExchange(runID: runID, messages: [user], outcome: .interrupted)
      ]), pendingRun: checkpoint)
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient())
    model.conversations = [pending]
    model.conversationPersistenceState.persistableConversations[pending.id] = pending

    #expect(await model.renameConversation(pending.id, to: "Investigate pending work"))
    #expect(model.conversations.first?.pendingRun == checkpoint)
    #expect(model.conversations.first?.history == pending.history)
    #expect(!(await model.setConversationArchived(pending.id, archived: true)))
    #expect(model.errorMessage?.contains("unresolved") == true)
    #expect(model.conversations.first?.isArchived == false)
  }

  @Test @MainActor
  func historicalInterruptionCanBeArchivedOnlyWhenItsToolCallsHaveKnownResults() async throws {
    var known = completedConversation()
    known.history?.exchanges[0].outcome = .interrupted
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient())
    model.conversations = [known]
    model.conversationPersistenceState.persistableConversations[known.id] = known
    #expect(await model.setConversationArchived(known.id, archived: true))
    #expect(await model.setConversationArchived(known.id, archived: false))
    model.conversations[0].history?.exchanges[0].messages.remove(at: 2)
    #expect(!(await model.setConversationArchived(known.id, archived: true)))
    #expect(model.conversations.first?.isArchived == false)
  }

  @Test @MainActor
  func oversizedOffSelectionRenameUpdatesDurableFallbackWithoutDiscardingFullOutput() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AgentConversationStore(
      fileURL: root.appendingPathComponent("conversations.json"))
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient(), conversationStore: store)
    await model.restoreConversationHistory()
    model.newConversation()
    let first = try #require(model.selectedConversationID)
    model.appendTool("Saved output")
    await model.conversationPersistenceTask?.value
    let fullOutput = String(repeating: "x", count: AgentConversation.maximumPersistedTextBytes + 1)
    model.appendTool(fullOutput)
    await model.conversationPersistenceTask?.value
    model.newConversation()
    let selected = model.selectedConversationID
    await model.conversationPersistenceTask?.value

    #expect(await model.renameConversation(first, to: "Keep full output open"))
    #expect(model.selectedConversationID == selected)
    #expect(
      model.conversations.first(where: { $0.id == first })?.transcript.last?.text == fullOutput)
    let durable = try #require(try await store.load()?.conversations.first { $0.id == first })
    #expect(durable.title == "Keep full output open")
    #expect(durable.transcript.last?.text == "Saved output")
    #expect(!(await model.setConversationArchived(first, archived: true)))
    #expect(model.conversations.first(where: { $0.id == first })?.isArchived == false)
  }

  @Test @MainActor
  func saveFailureLeavesMetadataAndLastPersistableSnapshotUnchanged() async throws {
    let initial = AgentConversation(title: "Original")
    let archive = AgentConversationArchive(
      selectedConversationID: initial.id, conversations: [initial])
    let store = ControlledStore(initial: archive, shouldFail: true)
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient(), conversationStore: store)
    await model.restoreConversationHistory()
    let originals = model.conversations
    let fallback = model.conversationPersistenceState.persistableConversations
    #expect(!(await model.renameConversation(initial.id, to: "Not saved")))
    #expect(model.conversations == originals)
    #expect(model.conversationPersistenceState.persistableConversations == fallback)
    #expect(model.conversationSaveError != nil)
    #expect(try await store.load() == archive)
  }

  @Test @MainActor
  func saveReceiptPrecedesVisibleMetadataAndBlocksConcurrentSwitchOrRetry() async throws {
    let initial = AgentConversation(title: "Original")
    let archive = AgentConversationArchive(
      selectedConversationID: initial.id, conversations: [initial])
    let store = ControlledStore(initial: archive, holdWrite: true)
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient(), conversationStore: store)
    await model.restoreConversationHistory()
    model.runState = .failed
    model.isFailedRunRetryAvailable = true
    model.currentRunRequest = GatewayStartRunRequest(
      runID: AgentRunID(), modelID: ModelID(rawValue: "fixture"),
      initialMessages: [Message(role: .user, content: [.text("Earlier failed request")])])
    let rename = Task { await model.renameConversation(initial.id, to: "Saved name") }
    await store.waitForWrite()
    #expect(model.conversations.first?.title == "Original")
    #expect(!model.canOrganizeConversation(initial.id))
    model.newConversation()
    #expect(model.conversations.count == 1)
    model.retryLastFailure()
    #expect(model.runState == .failed)
    #expect(model.runTask == nil)
    await store.release()
    #expect(await rename.value)
    #expect(model.conversations.first?.title == "Saved name")
    #expect(try await store.load()?.conversations.first?.title == "Saved name")
  }

  @Test @MainActor
  func connectingCannotScheduleRecoveryInsideTheMetadataSaveBarrier() async {
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient())
    model.needsRunRecovery = true
    model.currentRunRequest = GatewayStartRunRequest(
      runID: AgentRunID(), modelID: ModelID(rawValue: "fixture"),
      initialMessages: [Message(role: .user, content: [.text("Recover original request")])])
    model.isPreparingAdmission = true
    await model.connect()
    #expect(model.needsRunRecovery)
    #expect(model.runTask == nil)
    #expect(!model.isRecoveringRun)
    model.isPreparingAdmission = false
  }

  private nonisolated func completedConversation() -> AgentConversation {
    let runID = AgentRunID()
    let call = ToolCall(name: "inspect", arguments: [:])
    let reference = ArtifactReference(
      id: UUID(), runID: runID, toolCallID: call.id, mediaType: "text/plain",
      byteCount: 8, sha256: String(repeating: "a", count: 64), isComplete: true)
    let result = ToolResult(
      toolCallID: call.id, status: .success, output: .string("Saved output"), artifacts: [reference]
    )
    return AgentConversation(
      title: "Original", transcript: [ConversationItem(role: .assistant, text: "Finished")],
      history: AgentConversationHistory(exchanges: [
        AgentConversationExchange(
          runID: runID,
          messages: [
            Message(role: .user, content: [.text("Inspect")]),
            Message(role: .assistant, content: [.toolCall(call)]),
            Message(role: .tool, content: [.toolResult(result)]),
            Message(role: .assistant, content: [.text("Finished")]),
          ], outcome: .completed)
      ]), artifactInventory: [reference])
  }

  private nonisolated func directory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("hex-organization-workspace-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
  }

  private enum SaveFailure: Error { case expected }

  private actor ControlledStore: AgentConversationStoring {
    private var archive: AgentConversationArchive
    private let shouldFail: Bool
    private let holdWrite: Bool
    private var isWriting = false
    private var held: CheckedContinuation<Void, Never>?
    private var entered: [CheckedContinuation<Void, Never>] = []

    init(initial: AgentConversationArchive, shouldFail: Bool = false, holdWrite: Bool = false) {
      archive = initial
      self.shouldFail = shouldFail
      self.holdWrite = holdWrite
    }
    func load() async throws -> AgentConversationArchive? { archive }
    func save(_ value: AgentConversationArchive) async throws {
      if shouldFail { throw SaveFailure.expected }
      if holdWrite {
        await withCheckedContinuation { continuation in
          held = continuation
          isWriting = true
          for waiter in entered { waiter.resume() }
          entered.removeAll()
        }
      }
      archive = value
    }
    nonisolated func validateForPersistence(_ value: AgentConversationArchive) throws {
      try AgentConversationStore.validateForPersistence(value)
    }
    func waitForWrite() async {
      if isWriting { return }
      await withCheckedContinuation { entered.append($0) }
    }
    func release() {
      held?.resume()
      held = nil
    }
  }
}
