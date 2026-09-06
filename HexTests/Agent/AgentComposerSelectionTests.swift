import Foundation
import HexCore
import HexIPC
import Testing

@testable import Hex

@Suite("Agent composer selection")
struct AgentComposerSelectionTests {
  @Test @MainActor
  func automaticDefaultsAndChosenValuesReachTheRunRequest() async throws {
    let (store, cleanup) = try makePreferenceStore()
    defer { cleanup() }
    let model = AgentWorkspaceModel(
      client: PreviewHexAgentClient(),
      modelID: "gpt-5.6-luna",
      conversationStore: nil,
      composerPreferenceStore: store
    )

    #expect(model.selectedComposerModelID == nil)
    #expect(model.selectedComposerEffort == .automatic)
    #expect(model.availableComposerModels.map(\.displayName) == ["GPT-5.6 Luna"])
    await model.connect()
    model.discoveredModels = catalogModels

    model.selectedComposerModelID = "gpt-5.6-luna"
    model.selectedComposerEffort = .high
    model.draft = "Inspect this project"
    model.send()

    let request = try #require(model.currentRunRequest)
    #expect(request.modelID == ModelID(rawValue: "gpt-5.6-luna"))
    #expect(request.options.reasoningEffort == .high)

    let restored = AgentWorkspaceModel(
      client: PreviewHexAgentClient(),
      modelID: "gpt-5.6-luna",
      conversationStore: nil,
      composerPreferenceStore: store
    )
    #expect(restored.selectedComposerModelID == "gpt-5.6-luna")
    #expect(restored.selectedComposerEffort == .high)
  }

  @Test @MainActor
  func unavailableRememberedModelStaysVisibleAndCannotSilentlyChange() throws {
    let (store, cleanup) = try makePreferenceStore()
    defer { cleanup() }
    store.saveSelectedModelID("gpt-no-longer-configured")

    let model = AgentWorkspaceModel(
      client: PreviewHexAgentClient(),
      modelID: "gpt-5.6-luna",
      conversationStore: nil,
      composerPreferenceStore: store
    )

    #expect(model.selectedComposerModelID == "gpt-no-longer-configured")
    #expect(!model.isComposerSelectionAvailable)
    #expect(model.availableComposerModels.map(\.id) == [ModelID(rawValue: "gpt-5.6-luna")])
  }

  @Test @MainActor
  func activeRunPreventsComposerSelectionChanges() throws {
    let (store, cleanup) = try makePreferenceStore()
    defer { cleanup() }
    let model = AgentWorkspaceModel(
      client: PreviewHexAgentClient(),
      modelID: "gpt-5.6-luna",
      conversationStore: nil,
      composerPreferenceStore: store
    )
    model.discoveredModels = catalogModels
    model.selectedComposerEffort = .low
    model.runState = .running

    model.selectedComposerModelID = "gpt-5.6-luna"
    model.selectedComposerEffort = .extraHigh

    #expect(model.selectedComposerModelID == nil)
    #expect(model.selectedComposerEffort == .low)
    #expect(!model.canChangeComposerOptions)
  }

  @Test @MainActor
  func switchingModelsPreservesHistoryAndEachConversationsChoice() throws {
    let (store, cleanup) = try makePreferenceStore()
    defer { cleanup() }
    let model = AgentWorkspaceModel(
      client: PreviewHexAgentClient(), modelID: "gpt-5.6-luna",
      conversationStore: nil, composerPreferenceStore: store)
    model.discoveredModels = catalogModels
    model.newConversation()
    let firstID = try #require(model.selectedConversationID)
    model.transcript = [ConversationItem(role: .user, text: "Keep this history")]
    model.selectedComposerModelID = "gpt-5.6-luna"
    model.selectedComposerEffort = .high
    model.updateCurrentConversation()
    model.newConversation()
    model.selectedComposerModelID = "gpt-5.6-sol"
    model.selectedComposerEffort = .ultra
    model.updateCurrentConversation()

    model.selectConversation(firstID)
    #expect(model.selectedComposerModelID == "gpt-5.6-luna")
    #expect(model.selectedComposerEffort == .high)
    #expect(model.transcript.map(\.text) == ["Keep this history"])
    #expect(!model.availableComposerEfforts.contains(.ultra))
    model.selectedComposerEffort = .ultra
    #expect(model.selectedComposerEffort == .high)

    let roundTrip = try JSONDecoder().decode(
      AgentConversation.self,
      from: JSONEncoder().encode(
        try #require(model.conversations.first(where: { $0.id == firstID }))))
    #expect(roundTrip.composerSelection?.modelID == "gpt-5.6-luna")
    #expect(roundTrip.composerSelection?.effort == .high)
  }

  @Test @MainActor
  func approvalOverrideSurvivesRealArchiveReloadAndDefaultsStayConversationLocal() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("HexComposerPermissions-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("history.json")
    let store = try AgentConversationStore(fileURL: fileURL)
    let legacy = AgentConversation(
      composerSelection: AgentComposerSelection(modelID: nil, effort: .automatic))
    try await store.save(
      AgentConversationArchive(selectedConversationID: legacy.id, conversations: [legacy]))
    let legacyBytes = try Data(contentsOf: fileURL)
    #expect(!String(decoding: legacyBytes, as: UTF8.self).contains("authorizationMode"))
    let loadedLegacy = try #require(try await store.load())
    try await store.save(loadedLegacy)
    #expect(try Data(contentsOf: fileURL) == legacyBytes)

    let client = PermissionRecordingClient()
    let model = AgentWorkspaceModel(
      client: client, conversationStore: store, defaultAuthorizationMode: .approveForMe)
    await model.restoreConversationHistory()
    #expect(model.selectedComposerAuthorizationMode == .approveForMe)
    #expect(model.rememberedComposerAuthorizationMode == nil)
    model.selectedComposerAuthorizationMode = .fullAccess
    model.newConversation()
    let inheritedID = try #require(model.selectedConversationID)
    #expect(model.selectedComposerAuthorizationMode == .approveForMe)
    #expect(model.rememberedComposerAuthorizationMode == nil)
    model.selectConversation(legacy.id)
    #expect(model.selectedComposerAuthorizationMode == .fullAccess)
    await model.conversationPersistenceTask?.value

    let reopenedStore = try AgentConversationStore(fileURL: fileURL)
    let restored = AgentWorkspaceModel(
      client: client, conversationStore: reopenedStore, defaultAuthorizationMode: .askEveryTime)
    await restored.restoreConversationHistory()
    #expect(restored.selectedComposerAuthorizationMode == .fullAccess)
    restored.selectConversation(inheritedID)
    #expect(restored.selectedComposerAuthorizationMode == .askEveryTime)
    #expect(restored.rememberedComposerAuthorizationMode == nil)
    restored.selectConversation(legacy.id)
    await restored.connect()
    restored.draft = "Use this conversation's explicit policy"
    restored.send()
    let admitted = try #require(restored.currentRunRequest)
    #expect(admitted.authorizationMode == .fullAccess)
    restored.defaultAuthorizationMode = .approveForMe
    restored.selectedComposerAuthorizationMode = .askEveryTime
    #expect(!restored.canChangeComposerAuthorizationMode)
    #expect(restored.selectedComposerAuthorizationMode == .fullAccess)
    #expect(restored.currentRunRequest == admitted)
    await restored.runTask?.value
    await restored.conversationPersistenceTask?.value
    #expect(await client.requests == [admitted])

    restored.selectConversation(inheritedID)
    restored.draft = "Use the saved resident default"
    restored.send()
    await restored.runTask?.value
    await restored.conversationPersistenceTask?.value
    #expect(await client.requests.last?.authorizationMode == .approveForMe)
    let saved = try #require(try await reopenedStore.load())
    #expect(
      saved.conversations.first { $0.id == legacy.id }?.composerSelection?.authorizationMode
        == .fullAccess)
    #expect(
      saved.conversations.first { $0.id == inheritedID }?.composerSelection?.authorizationMode
        == nil)
  }

  @Test @MainActor
  func approvalChangesCannotRewriteRecoveryOrBypassAPersistenceFailure() {
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient())
    #expect(model.selectedComposerAuthorizationMode == .askEveryTime)
    model.selectedComposerAuthorizationMode = .approveForMe
    model.conversationSaveError = "The archive could not be saved."
    model.selectedComposerAuthorizationMode = .fullAccess
    #expect(!model.canChangeComposerAuthorizationMode)
    #expect(model.selectedComposerAuthorizationMode == .approveForMe)
    model.conversationSaveError = nil
    model.currentRunRequest = GatewayStartRunRequest(
      runID: AgentRunID(), modelID: ModelID(rawValue: "preview"), initialMessages: [],
      authorizationMode: .askEveryTime)
    let original = model.currentRunRequest
    model.needsRunRecovery = true
    model.selectedComposerAuthorizationMode = .fullAccess
    #expect(!model.canChangeComposerAuthorizationMode)
    #expect(model.currentRunRequest == original)
    #expect(model.rememberedComposerAuthorizationMode == .approveForMe)
    #expect(model.selectedComposerAuthorizationMode == .askEveryTime)
    model.needsRunRecovery = false
    model.isRecoveringRun = true
    model.selectedComposerAuthorizationMode = .fullAccess
    #expect(model.currentRunRequest == original)
    #expect(model.rememberedComposerAuthorizationMode == .approveForMe)
  }

  private actor PermissionRecordingClient: HexAgentClient {
    private let gatewayID = GatewayInstanceID()
    private(set) var requests: [GatewayStartRunRequest] = []

    func connect() async throws -> GatewayConnectionResult {
      GatewayConnectionResult(
        response: GatewayHandshakeResponse(
          sessionID: GatewaySessionID(), gatewayInstanceID: gatewayID,
          selectedVersion: .current, activeRun: nil), previousGatewayInstanceID: nil)
    }
    func disconnect() async throws {}
    func startRun(_ request: GatewayStartRunRequest) async throws -> GatewayStartRunResponse {
      requests.append(request)
      return GatewayStartRunResponse(
        runID: request.runID,
        disposition: .started(invocationID: GatewayRunInvocationID(rawValue: UUID())))
    }
    func eventRecords(for runID: AgentRunID, invocationID: GatewayRunInvocationID) async throws
      -> AsyncThrowingStream<GatewayEventEnvelope, any Error>
    {
      AsyncThrowingStream { continuation in
        continuation.yield(
          GatewayEventEnvelope(
            invocationID: invocationID,
            record: AgentEventRecord(
              id: AgentEventID(), runID: runID, sequence: 1, timestamp: Date(), event: .runCompleted
            )))
        continuation.finish()
      }
    }
    func cancelRun(_ request: GatewayCancelRunRequest) async throws -> GatewayCancelRunResponse {
      GatewayCancelRunResponse(
        runID: request.runID, invocationID: request.invocationID, disposition: .alreadyTerminal)
    }
    func shouldApply(_ envelope: GatewayEventEnvelope) async throws -> Bool { true }
    func acknowledge(_ envelope: GatewayEventEnvelope) async throws {}
    func decideAuthorization(_ request: AuthorizationRequest, choice: AuthorizationDecisionChoice)
      async throws
    {}
  }

  private var catalogModels: [ModelDescriptor] {
    [
      ModelDescriptor(
        id: ModelID(rawValue: "gpt-5.6-luna"), providerID: ProviderID(rawValue: "openai"),
        displayName: "GPT-5.6 Luna", capabilities: [.textInput, .reasoningSummary],
        supportedReasoningEfforts: [.low, .medium, .high]),
      ModelDescriptor(
        id: ModelID(rawValue: "gpt-5.6-sol"), providerID: ProviderID(rawValue: "openai"),
        displayName: "GPT-5.6 Sol", capabilities: [.textInput, .reasoningSummary],
        supportedReasoningEfforts: [.low, .medium, .high, .ultra]),
    ]
  }

  @MainActor
  private func makePreferenceStore() throws
    -> (UserDefaultsAgentComposerPreferenceStore, () -> Void)
  {
    let suiteName = "AgentComposerSelectionTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return (
      UserDefaultsAgentComposerPreferenceStore(userDefaults: defaults),
      { defaults.removePersistentDomain(forName: suiteName) }
    )
  }
}
