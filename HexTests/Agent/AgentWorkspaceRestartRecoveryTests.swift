import Foundation
import HexCore
import HexIPC
import Testing

@testable import Hex

@Suite("Workspace restart recovery without readmission")
struct AgentWorkspaceRestartRecoveryTests {
  @Test(arguments: [RecoveryMode.resident, .journaled]) @MainActor
  func restoredCheckpointAppliesOnlyTheSuffixToItsOriginalPartialRow(_ mode: RecoveryMode)
    async throws
  {
    let seed = try seed()
    let store = CheckpointStore(archive: seed.archive)
    let client = RecoveryClient(seed: seed, mode: mode, store: store)
    let model = AgentWorkspaceModel(
      client: client, modelID: "different-default", conversationStore: store)

    await model.restoreConversationHistory()
    await model.connect()
    await model.runTask?.value
    await model.conversationPersistenceTask?.value

    #expect(await client.startRequests.isEmpty)
    #expect(await client.recoveryRequests.map(\.runID) == [seed.request.runID])
    #expect(model.runState == .completed)
    let assistantRows = model.transcript.filter { $0.role == .assistant }
    #expect(assistantRows.map(\.text) == ["Hello"])
    #expect(assistantRows.first?.id == seed.partialRowID)
    let saved = try #require(try await store.load()?.conversations.first)
    #expect(saved.pendingRun == nil)
    #expect(saved.history?.exchanges.last?.lastEventSequence == 6)
    #expect(saved.history?.exchanges.last?.messages == [seed.userMessage, seed.assistantMessage])
    #expect(saved.contextMessages() == [seed.userMessage, seed.assistantMessage])
    #expect(model.errorMessage == nil)
    let streams = await client.streamCursors
    let pages = await client.historyRequests
    if mode == .resident {
      #expect(streams == [3])
      let acknowledgements = await client.acknowledgements
      #expect(acknowledgements.map(\.recordSequence) == [4, 5, 6])
      // Live receipt may advance ahead of a coalesced disk checkpoint. The saved cursor and
      // saved row must nevertheless describe one exact prefix, never a mixed snapshot.
      #expect(
        acknowledgements.allSatisfy {
          $0.persistedSequence >= 3 && $0.persistedSequence <= $0.recordSequence
            && $0.persistedPartialText == ($0.persistedSequence == 3 ? "Hel" : "Hello")
        })
    } else {
      #expect(streams.isEmpty)
      #expect(pages.map(\.afterSequence) == [3, 4, 5])
      #expect(
        pages.allSatisfy { $0.firstEventID == seed.records.first?.id && $0.throughSequence == 6 })
    }
  }

  @Test(arguments: [false, true]) @MainActor
  func unknownOriginalRunIsNeverSubmittedAgain(unadmitted: Bool) async throws {
    let seed = try seed(unadmitted: unadmitted)
    let store = CheckpointStore(archive: seed.archive)
    let client = RecoveryClient(seed: seed, mode: .unknown, store: store)
    let model = AgentWorkspaceModel(client: client, conversationStore: store)
    await model.restoreConversationHistory()
    await model.connect()
    await model.runTask?.value

    #expect(await client.startRequests.isEmpty)
    #expect(await client.recoveryRequests.map(\.runID) == [seed.request.runID])
    #expect(model.runState != .completed)
    #expect(model.errorMessage != nil)
    #expect(model.conversations.first?.pendingRun?.request == seed.request)
    model.draft = "Do not replace the uncertain request"
    model.send()
    await model.runTask?.value
    #expect(await client.startRequests.isEmpty)
    #expect(model.draft == "Do not replace the uncertain request")
  }

  @Test @MainActor
  func helperRestartReplaysInterruptionWithoutRepeatingAnUncertainToolAction() async throws {
    let seed = try seed(toolInterruption: true)
    let store = CheckpointStore(archive: seed.archive)
    let client = RecoveryClient(seed: seed, mode: .journaled, store: store)
    let model = AgentWorkspaceModel(client: client, conversationStore: store)
    await model.restoreConversationHistory()
    await model.connect()
    await model.runTask?.value
    await model.conversationPersistenceTask?.value

    #expect(model.runState == .failed)
    #expect(!model.canRetryLastFailure)
    #expect(model.errorMessage != nil)
    #expect(await client.startRequests.isEmpty)
    #expect(await client.streamCursors.isEmpty)
    #expect(await client.authorizationSubmissions == 0)
    let conversation = try #require(try await store.load()?.conversations.first)
    #expect(conversation.history?.exchanges.last?.outcome == .failed)
    #expect(
      conversation.history?.exchanges.last?.messages
        == seed.archive.conversations.first?.history?.exchanges.last?.messages)
    model.retryLastFailure()
    await model.runTask?.value
    #expect(await client.startRequests.isEmpty)
  }

  @Test @MainActor
  func failedJournalPageSaveCannotAdvanceOrOverwriteTheLastCommittedPrefix() async throws {
    let seed = try seed()
    let store = CheckpointStore(archive: seed.archive, failAtOrAfterSequence: 4)
    let client = RecoveryClient(seed: seed, mode: .journaled, store: store)
    let model = AgentWorkspaceModel(client: client, conversationStore: store)
    await model.restoreConversationHistory()
    await model.connect()
    await model.runTask?.value
    await model.conversationPersistenceTask?.value

    #expect(await client.startRequests.isEmpty)
    #expect(await client.acknowledgements.isEmpty)
    #expect(await client.streamCursors.isEmpty)
    #expect(await client.historyRequests.map(\.afterSequence) == [3])
    #expect(model.runState != .completed)
    #expect(model.errorMessage != nil)
    let retained = try #require(try await store.load()?.conversations.first)
    #expect(retained.pendingRun?.appliedSequence == 3)
    #expect(retained.pendingRun?.request == seed.request)
    #expect(retained.history?.exchanges.last?.lastEventSequence == 3)
    #expect(retained.transcript.first(where: { $0.id == seed.partialRowID })?.text == "Hel")
    #expect(retained.history?.exchanges.last?.messages == [seed.userMessage])
  }

  @Test @MainActor
  func terminalRecoveryKeepsNavigationAndAdmissionLockedUntilItsCheckpointIsSaved() async throws {
    let seed = try seed()
    let other = AgentConversation(title: "Another conversation")
    let archive = AgentConversationArchive(
      selectedConversationID: seed.archive.selectedConversationID,
      conversations: seed.archive.conversations + [other])
    let store = CheckpointStore(archive: archive, blockedSequence: 6)
    let client = RecoveryClient(seed: seed, mode: .journaled, store: store)
    let model = AgentWorkspaceModel(client: client, conversationStore: store)
    await model.restoreConversationHistory()
    await model.connect()
    do {
      try await waitUntil { await store.isSaveBlocked }
    } catch {
      await store.releaseBlockedSave()
      model.runTask?.cancel()
      throw error
    }

    // A terminal event has been reduced, but recovery still owns the original conversation until
    // the corresponding durable page commits. Run state alone must not unlock these controls.
    #expect(model.runState == .completed)
    #expect(model.isRecoveringRun)
    #expect(model.isRunActive)
    model.draft = "Do not dispatch during terminal checkpoint saving"
    #expect(!model.canSend)
    model.selectConversation(other.id)
    model.newConversation()
    model.send()
    #expect(model.selectedConversationID == seed.archive.selectedConversationID)
    #expect(model.conversations.count == 2)
    #expect(model.draft == "Do not dispatch during terminal checkpoint saving")
    #expect(await client.startRequests.isEmpty)
    #expect(await client.streamCursors.isEmpty)
    #expect(try await store.load()?.conversations.first?.pendingRun?.appliedSequence == 5)

    await store.releaseBlockedSave()
    await model.runTask?.value
    await model.conversationPersistenceTask?.value
    #expect(!model.isRecoveringRun)
    #expect(!model.isRunActive)
    #expect(model.runState == .completed)
    #expect(try await store.load()?.conversations.first?.pendingRun == nil)
    #expect(
      try await store.load()?.conversations.first?.history?.exchanges.last?.lastEventSequence == 6)
    model.selectConversation(other.id)
    #expect(model.selectedConversationID == other.id)
    #expect(await client.startRequests.isEmpty)
    await model.conversationPersistenceTask?.value
  }

  @MainActor
  private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
    for _ in 0..<200 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw FixtureError.timedOut
  }

  private func seed(unadmitted: Bool = false, toolInterruption: Bool = false) throws -> Seed {
    let runID = AgentRunID()
    let user = Message(role: .user, content: [.text("Say hello after inspecting the project")])
    let assistant = Message(role: .assistant, content: [.text("Hello")])
    let request = GatewayStartRunRequest(
      runID: runID, modelID: ModelID(rawValue: "original-model"), initialMessages: [user],
      options: InferenceOptions(reasoningEffort: .low),
      workingDirectory: URL(fileURLWithPath: "/sample"))
    let gateway = GatewayInstanceID()
    let invocation = GatewayRunInvocationID(rawValue: UUID())
    let partial = ConversationItem(role: .assistant, text: "Hel", isStreaming: true)
    var transcript = [ConversationItem(role: .user, text: "Say hello after inspecting the project")]
    let events: [AgentEvent]
    let savedMessages: [Message]
    let applied: UInt64
    if toolInterruption {
      let call = ToolCall(name: "write_file", arguments: ["path": .string("/sample/result.txt")])
      let message = Message(role: .assistant, content: [.toolCall(call)])
      events = [
        .runStarted, .messageAppended(user), .messageAppended(message), .toolStarted(call),
        .runFailed(
          AgentFailure(
            code: .invalidState, message: "Gateway restarted during tool execution.",
            isRetryable: false)),
      ]
      savedMessages = [user, message]
      applied = 4
      transcript.append(ConversationItem(role: .tool, text: "Started write_file"))
    } else {
      events = [
        .runStarted, .messageAppended(user), .inferenceEvent(.textDelta("Hel")),
        .inferenceEvent(.textDelta("lo")), .messageAppended(assistant), .runCompleted,
      ]
      savedMessages = [user]
      applied = unadmitted ? 0 : 3
      if !unadmitted { transcript.append(partial) }
    }
    let records = events.enumerated().map {
      AgentEventRecord(
        id: AgentEventID(), runID: runID, sequence: UInt64($0.offset + 1), timestamp: Date(),
        event: $0.element)
    }
    let checkpoint = AgentConversationRunCheckpoint(
      request: request, gatewayInstanceID: unadmitted ? nil : gateway,
      invocationID: unadmitted ? nil : invocation, appliedSequence: applied,
      firstEventID: applied == 0 ? nil : records.first?.id,
      streamingAssistantItemID: unadmitted || toolInterruption ? nil : partial.id,
      hasToolEvidence: toolInterruption)
    let conversation = AgentConversation(
      title: "Interrupted request", transcript: transcript,
      history: AgentConversationHistory(exchanges: [
        AgentConversationExchange(
          runID: runID, messages: savedMessages, outcome: .inProgress,
          lastEventSequence: applied == 0 ? nil : applied)
      ]), pendingRun: checkpoint)
    let archive = AgentConversationArchive(
      selectedConversationID: conversation.id, conversations: [conversation])
    try AgentConversationStore.validateForPersistence(archive)
    return Seed(
      archive: archive, request: request, records: records, gateway: gateway,
      invocation: invocation, appliedSequence: applied, partialRowID: partial.id,
      userMessage: user, assistantMessage: assistant)
  }

  enum RecoveryMode: Equatable, Sendable { case resident, journaled, unknown }

  private struct Seed: Sendable {
    let archive: AgentConversationArchive
    let request: GatewayStartRunRequest
    let records: [AgentEventRecord]
    let gateway: GatewayInstanceID
    let invocation: GatewayRunInvocationID
    let appliedSequence: UInt64
    let partialRowID: UUID
    let userMessage: Message
    let assistantMessage: Message
  }

  private enum FixtureError: Error { case unexpectedAdmission, invalidCursor, saveFailed, timedOut }

  private actor CheckpointStore: AgentConversationStoring {
    var archive: AgentConversationArchive
    let failAtOrAfterSequence: UInt64?
    let blockedSequence: UInt64?
    private var blockedSave: CheckedContinuation<Void, Never>?
    private var releasedBlockedSave = false
    var isSaveBlocked: Bool { blockedSave != nil }
    init(
      archive: AgentConversationArchive, failAtOrAfterSequence: UInt64? = nil,
      blockedSequence: UInt64? = nil
    ) {
      self.archive = archive
      self.failAtOrAfterSequence = failAtOrAfterSequence
      self.blockedSequence = blockedSequence
    }
    func load() async throws -> AgentConversationArchive? { archive }
    func save(_ archive: AgentConversationArchive) async throws {
      try validateForPersistence(archive)
      if let limit = failAtOrAfterSequence,
        archive.conversations.contains(where: {
          ($0.history?.exchanges.last?.lastEventSequence ?? 0) >= limit
        })
      {
        throw FixtureError.saveFailed
      }
      if let blockedSequence, !releasedBlockedSave,
        archive.conversations.contains(where: {
          $0.history?.exchanges.last?.lastEventSequence == blockedSequence
        })
      {
        await withCheckedContinuation { blockedSave = $0 }
      }
      self.archive = archive
    }
    func releaseBlockedSave() {
      releasedBlockedSave = true
      blockedSave?.resume()
      blockedSave = nil
    }
    nonisolated func validateForPersistence(_ archive: AgentConversationArchive) throws {
      try AgentConversationStore.validateForPersistence(archive)
    }
  }

  private struct Acknowledgement: Sendable {
    let recordSequence: UInt64
    let persistedSequence: UInt64
    let persistedPartialText: String?
  }

  private actor RecoveryClient: HexAgentClient {
    let seed: Seed
    let mode: RecoveryMode
    let store: CheckpointStore
    let gateway: GatewayInstanceID
    private(set) var startRequests: [GatewayStartRunRequest] = []
    private(set) var recoveryRequests: [GatewayRunRecoveryRequest] = []
    private(set) var historyRequests: [GatewayRunHistoryRequest] = []
    private(set) var streamCursors: [UInt64] = []
    private(set) var acknowledgements: [Acknowledgement] = []
    private(set) var authorizationSubmissions = 0

    init(seed: Seed, mode: RecoveryMode, store: CheckpointStore) {
      self.seed = seed
      self.mode = mode
      self.store = store
      gateway = mode == .resident ? seed.gateway : GatewayInstanceID()
    }
    func connect() async throws -> GatewayConnectionResult {
      GatewayConnectionResult(
        response: GatewayHandshakeResponse(
          sessionID: GatewaySessionID(),
          gatewayInstanceID: gateway, selectedVersion: .current, activeRun: nil),
        previousGatewayInstanceID: nil)
    }
    func disconnect() async throws {}
    func startRun(_ request: GatewayStartRunRequest) async throws -> GatewayStartRunResponse {
      startRequests.append(request)
      throw FixtureError.unexpectedAdmission
    }
    func recoverRun(_ request: GatewayRunRecoveryRequest) async throws -> GatewayRunRecoveryResponse
    {
      recoveryRequests.append(request)
      guard request.runID == seed.request.runID else { throw FixtureError.invalidCursor }
      let disposition: GatewayRunRecoveryDisposition
      switch mode {
      case .unknown: disposition = .unknown
      case .journaled:
        disposition = .journaled(
          GatewayJournalRunSnapshot(
            runID: request.runID,
            firstEventID: seed.records[0].id, latestSequence: UInt64(seed.records.count),
            terminalRecord: seed.records.last))
      case .resident:
        disposition = .resident(
          snapshot: GatewayRunSnapshot(
            runID: request.runID,
            invocationID: seed.invocation, phase: .running, latestSequence: seed.appliedSequence),
          minimumReplaySequence: 0,
          journal: GatewayJournalRunSnapshot(
            runID: request.runID, firstEventID: seed.records[0].id,
            latestSequence: seed.appliedSequence, terminalRecord: nil))
      }
      return GatewayRunRecoveryResponse(
        gatewayInstanceID: gateway, runID: request.runID, disposition: disposition)
    }
    func readRunHistory(_ request: GatewayRunHistoryRequest) async throws -> GatewayRunHistoryPage {
      historyRequests.append(request)
      guard request.runID == seed.request.runID, request.firstEventID == seed.records[0].id,
        request.throughSequence <= UInt64(seed.records.count)
      else { throw FixtureError.invalidCursor }
      let records = Array(
        seed.records.filter {
          $0.sequence > request.afterSequence && $0.sequence <= request.throughSequence
        }.prefix(1))
      let last = records.last?.sequence ?? request.afterSequence
      return GatewayRunHistoryPage(
        gatewayInstanceID: gateway, runID: request.runID,
        firstEventID: request.firstEventID, afterSequence: request.afterSequence,
        throughSequence: request.throughSequence, records: records,
        nextAfterSequence: last < request.throughSequence ? last : nil)
    }
    func eventRecords(for runID: AgentRunID, invocationID: GatewayRunInvocationID) async throws
      -> AsyncThrowingStream<GatewayEventEnvelope, any Error>
    { try await eventRecords(for: runID, invocationID: invocationID, afterSequence: 0) }
    func eventRecords(
      for runID: AgentRunID, invocationID: GatewayRunInvocationID, afterSequence: UInt64
    ) async throws
      -> AsyncThrowingStream<GatewayEventEnvelope, any Error>
    {
      guard mode == .resident, runID == seed.request.runID, invocationID == seed.invocation else {
        throw FixtureError.invalidCursor
      }
      streamCursors.append(afterSequence)
      let records = seed.records.filter { $0.sequence > afterSequence }
      return AsyncThrowingStream { continuation in
        for record in records {
          continuation.yield(GatewayEventEnvelope(invocationID: invocationID, record: record))
        }
        continuation.finish()
      }
    }
    func shouldApply(_ envelope: GatewayEventEnvelope) async throws -> Bool { true }
    func acknowledge(_ envelope: GatewayEventEnvelope) async throws {
      let conversation = try await store.load()?.conversations.first
      acknowledgements.append(
        Acknowledgement(
          recordSequence: envelope.record.sequence,
          persistedSequence: conversation?.history?.exchanges.last?.lastEventSequence ?? 0,
          persistedPartialText: conversation?.transcript.first(where: { $0.id == seed.partialRowID }
          )?.text))
    }
    func decideAuthorization(_ request: AuthorizationRequest, choice: AuthorizationDecisionChoice)
      async throws
    {
      authorizationSubmissions += 1
    }
    func cancelRun(_ request: GatewayCancelRunRequest) async throws -> GatewayCancelRunResponse {
      GatewayCancelRunResponse(
        runID: request.runID, invocationID: request.invocationID, disposition: .notFound)
    }
  }
}
