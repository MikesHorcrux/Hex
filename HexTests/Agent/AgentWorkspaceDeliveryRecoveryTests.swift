import Foundation
import HexCore
import HexIPC
import Testing

@testable import Hex

@Suite("Automatic delivery recovery never readmits work")
struct AgentWorkspaceDeliveryRecoveryTests {
  @Test(arguments: [false, true]) @MainActor
  func movingReplayWindowRefreshesOnlyWithinABoundedReadOnlyRecovery(keepsMoving: Bool) async throws
  {
    let client = DeliveryClient(
      failureCode: .consumerTooSlow, mode: keepsMoving ? .windowKeepsMoving : .windowMoved)
    let model = AgentWorkspaceModel(client: client)
    await model.connect()
    model.draft = "Say hello"
    model.send()
    try await waitUntil { model.runTask == nil }
    #expect(await client.startRequests.count == 1)
    #expect(await client.cancelCount == 0)
    #expect(await client.recoveryRequests.count == (keepsMoving ? 3 : 2))
    #expect(await client.reattachCount == (keepsMoving ? 3 : 1))
    #expect(model.runState == (keepsMoving ? .failed : .completed))
    if keepsMoving {
      #expect(model.needsRunRecovery)
      #expect(model.activity.contains("not been sent again"))
    } else {
      #expect(model.transcript.filter { $0.role == .assistant }.map(\.text) == ["Hello"])
      #expect(model.errorMessage == nil)
    }
  }

  @Test(arguments: [GatewayFailureCode.consumerTooSlow, .disconnected, .replayUnavailable])
  @MainActor
  func deliveryFailureRecoversTheOriginalPartialReplyOnce(_ code: GatewayFailureCode) async throws {
    let client = DeliveryClient(failureCode: code)
    let store = MemoryStore()
    let model = AgentWorkspaceModel(client: client, conversationStore: store)
    await model.restoreConversationHistory()
    await model.connect()
    model.draft = "Say hello"
    model.send()
    try await waitUntil { model.runTask == nil }
    await model.conversationPersistenceTask?.value

    #expect(model.runState == .completed)
    #expect(model.transcript.filter { $0.role == .assistant }.map(\.text) == ["Hello"])
    #expect(model.errorMessage == nil)
    #expect(await client.startRequests.count == 1)
    #expect(await client.recoveryRequests.map(\.runID) == client.startRequests.map(\.runID))
    #expect(await client.connectCount == (code == .disconnected ? 2 : 1))
    #expect(await client.cancelCount == 0)
    let saved = try #require(try await store.load()?.conversations.first)
    #expect(saved.pendingRun == nil)
    #expect(saved.history?.exchanges.count == 1)
    #expect(saved.history?.exchanges.last?.outcome == .completed)
    #expect(saved.history?.exchanges.last?.lastEventSequence == 6)
  }

  @Test @MainActor
  func failedReattachmentDoesNotScheduleAnotherAutomaticAttempt() async throws {
    let client = DeliveryClient(failureCode: .consumerTooSlow, mode: .attachmentFails)
    let model = AgentWorkspaceModel(client: client)
    await model.connect()
    model.draft = "Say hello"
    model.send()
    try await waitUntil { model.runTask == nil }
    let request = try #require(model.currentRunRequest)
    let conversationID = try #require(model.selectedConversationID)
    model.scheduleAutomaticDeliveryRecovery(request, conversationID: conversationID)
    #expect(model.runTask == nil)
    #expect(model.needsRunRecovery)
    #expect(model.runState == .failed)
    #expect(model.activity.contains("not been sent again"))
    #expect(await client.recoveryRequests.count == 1)
    #expect(await client.reattachCount == 1)
    #expect(await client.startRequests.count == 1)

    // Explicit Retry may perform another read-only query, but must clean up its owned Task even
    // though this run's automatic-attempt marker remains set.
    model.retryLastFailure()
    try await waitUntil { model.runTask == nil }
    #expect(await client.recoveryRequests.count == 2)
    #expect(await client.startRequests.count == 1)
    #expect(!model.isRecoveringRun)
  }

  @Test(arguments: [false, true]) @MainActor
  func freshUserRetryTransfersOwnershipToItsAutomaticRecoveryTask(maintenance: Bool) async throws {
    let client = DeliveryClient(
      failureCode: .consumerTooSlow, mode: .heldQuery, failFirstRunTerminally: !maintenance,
      refuseFirstForMaintenance: maintenance)
    let model = AgentWorkspaceModel(client: client)
    await model.connect()
    model.draft = "Say hello"
    model.send()
    try await waitUntil { model.runTask == nil }
    #expect(model.retryRequiresFreshRunID)
    #expect(!model.needsRunRecovery)
    #expect(await client.startRequests.count == 1)
    #expect(await client.recoveryRequests.isEmpty)
    model.retryLastFailure()
    do {
      try await waitUntil { await client.isQueryHeld }
      #expect(model.runTask != nil)
      #expect(model.isRunActive)
      await client.releaseQuery()
      try await waitUntil { model.runState == .completed && model.runTask == nil }
    } catch {
      await client.releaseQuery()
      model.runTask?.cancel()
      throw error
    }
    #expect(await client.startRequests.count == 2)
    #expect(await client.recoveryRequests.count == 1)
    let requests = await client.startRequests
    #expect(requests[0].runID != requests[1].runID)
    #expect(await client.recoveryRequests.first?.runID == requests[1].runID)
  }

  @Test @MainActor
  func malformedEvidenceIsNotTreatedAsADeliveryRetry() async throws {
    let client = DeliveryClient(failureCode: .malformedPayload)
    let model = AgentWorkspaceModel(client: client)
    await model.connect()
    model.draft = "Say hello"
    model.send()
    try await waitUntil { model.runTask == nil }
    #expect(model.runState == .failed)
    #expect(await client.recoveryRequests.isEmpty)
    #expect(await client.connectCount == 1)
    #expect(await client.startRequests.count == 1)
  }

  @Test @MainActor
  func failedCheckpointSaveDoesNotReconnectOrQueryTheRun() async throws {
    let client = DeliveryClient(failureCode: .disconnected)
    let store = MemoryStore(failAfterSequence: 3)
    let model = AgentWorkspaceModel(client: client, conversationStore: store)
    await model.restoreConversationHistory()
    await model.connect()
    model.draft = "Say hello"
    model.send()
    try await waitUntil { model.runTask == nil }
    await model.conversationPersistenceTask?.value
    #expect(model.conversationSaveError != nil)
    #expect(model.runState == .failed)
    #expect(await client.recoveryRequests.isEmpty)
    #expect(await client.connectCount == 1)
    #expect(await client.startRequests.count == 1)
  }

  @Test @MainActor
  func disconnectCancelsOnlyAutomaticObservationAndDoesNotResendOrCancelResidentWork() async throws
  {
    let client = DeliveryClient(failureCode: .consumerTooSlow, mode: .heldQuery)
    let model = AgentWorkspaceModel(client: client)
    await model.connect()
    model.draft = "Say hello"
    model.send()
    do {
      try await waitUntil { await client.isQueryHeld }
      #expect(model.canDisconnect)
      #expect(!model.canCancelRun)
      await model.disconnect()
      try await waitUntil { model.runTask == nil }
    } catch {
      await client.releaseQuery()
      model.runTask?.cancel()
      throw error
    }
    #expect(model.connectionState == .disconnected)
    #expect(model.needsRunRecovery)
    #expect(model.automaticConnectionSuppressedByUser)
    #expect(await client.startRequests.count == 1)
    #expect(await client.recoveryRequests.count == 1)
    #expect(await client.cancelCount == 0)
    await model.connectAutomatically()
    #expect(await client.connectCount == 1)
  }

  @Test @MainActor
  func disconnectRemainsAvailableWhileAutomaticReconnectIsHeld() async throws {
    let client = DeliveryClient(failureCode: .disconnected, mode: .heldReconnect)
    let model = AgentWorkspaceModel(client: client)
    await model.connect()
    model.draft = "Say hello"
    model.send()
    do {
      try await waitUntil { await client.isConnectionHeld }
      #expect(model.connectionState == .connecting)
      #expect(model.isRunActive)
      #expect(model.canDisconnect)
      #expect(!model.canCancelRun)
      await model.disconnect()
      try await waitUntil { model.runTask == nil }
    } catch {
      await client.releaseConnection()
      model.runTask?.cancel()
      throw error
    }
    #expect(model.connectionState == .disconnected)
    #expect(model.automaticConnectionSuppressedByUser)
    #expect(model.needsRunRecovery)
    #expect(await client.startRequests.count == 1)
    #expect(await client.recoveryRequests.isEmpty)
    #expect(await client.cancelCount == 0)
    await model.connectAutomatically()
    #expect(await client.connectCount == 2)
  }

  @Test @MainActor
  func terminalAcknowledgementDrainBlocksNavigationButIsNotCancellableWork() async throws {
    let client = DeliveryClient(failureCode: .consumerTooSlow, mode: .heldTerminalAcknowledgement)
    let model = AgentWorkspaceModel(client: client)
    await model.connect()
    model.newConversation()
    let otherConversationID = try #require(model.selectedConversationID)
    model.newConversation()
    let currentConversationID = try #require(model.selectedConversationID)
    model.draft = "Say hello"
    model.send()
    do {
      try await waitUntil { await client.isTerminalAcknowledgementHeld }
      #expect(model.runState == .completed)
      #expect(model.transcript.filter { $0.role == .assistant }.map(\.text) == ["Hello"])
      #expect(model.runTask != nil)
      #expect(model.isRunActive)
      #expect(!model.canCancelRun)
      model.draft = "Next prompt"
      #expect(!model.canSend)
      let conversationCount = model.conversations.count
      model.selectConversation(otherConversationID)
      model.newConversation()
      model.send()
      model.cancel()
      #expect(model.selectedConversationID == currentConversationID)
      #expect(model.conversations.count == conversationCount)
      #expect(model.runState == .completed)
      #expect(await client.startRequests.count == 1)
      #expect(await client.cancelCount == 0)
      await client.releaseTerminalAcknowledgement()
      try await waitUntil { model.runTask == nil }
    } catch {
      await client.releaseTerminalAcknowledgement()
      model.runTask?.cancel()
      throw error
    }
    #expect(!model.isRunActive)
    #expect(!model.isRecoveringRun)
    #expect(model.canSend)
    model.selectConversation(otherConversationID)
    #expect(model.selectedConversationID == otherConversationID)
    #expect(await client.startRequests.count == 1)
    #expect(await client.recoveryRequests.count == 1)
  }

  @Test @MainActor
  func changedConversationPreventsAutomaticRecovery() async throws {
    let client = DeliveryClient(failureCode: .malformedPayload)
    let model = AgentWorkspaceModel(client: client)
    await model.connect()
    model.draft = "Say hello"
    model.send()
    try await waitUntil { model.runTask == nil }
    let request = try #require(model.currentRunRequest)
    model.scheduleAutomaticDeliveryRecovery(request, conversationID: UUID())
    #expect(model.runTask == nil)
    #expect(await client.recoveryRequests.isEmpty)
    #expect(await client.startRequests.count == 1)
  }

  @Test(arguments: [false, true]) @MainActor
  func lostDeliveryAfterCancelRecoversItsReceiptWithoutRepeatingWork(residentActive: Bool)
    async throws
  {
    let client = DeliveryClient(
      failureCode: .consumerTooSlow,
      mode: residentActive ? .cancellingResident : .cancelledJournal)
    let store = MemoryStore()
    let model = AgentWorkspaceModel(client: client, conversationStore: store)
    await model.restoreConversationHistory()
    await model.connect()
    model.draft = "Say hello"
    model.send()
    do {
      try await waitUntil { model.currentAppliedSequence == 3 }
      model.cancel()
      if residentActive {
        try await waitUntil { model.currentAppliedSequence == 4 }
        #expect(model.runState == .cancelling)
        #expect(!model.canCancelRun)
        #expect(model.cancellationRequested)
        await client.releaseCancellationTerminal()
      }
      try await waitUntil { model.runTask == nil }
    } catch {
      await client.releaseCancellationTerminal()
      model.runTask?.cancel()
      throw error
    }
    await model.conversationPersistenceTask?.value
    #expect(model.runState == .cancelled)
    #expect(model.transcript.filter { $0.role == .assistant }.map(\.text) == ["Hello"])
    #expect(!model.transcript.contains { $0.isStreaming })
    #expect(model.errorMessage == nil)
    #expect(!model.needsRunRecovery)
    #expect(await client.startRequests.count == 1)
    #expect(await client.cancelCount == 1)
    #expect(await client.recoveryRequests.map(\.runID) == client.startRequests.map(\.runID))
    let saved = try #require(try await store.load()?.conversations.first)
    #expect(saved.pendingRun == nil)
    #expect(saved.history?.exchanges.count == 1)
    #expect(saved.history?.exchanges.last?.outcome == .cancelled)
    #expect(saved.history?.exchanges.last?.lastEventSequence == 5)
  }

  @MainActor
  private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await condition()) {
      guard ContinuousClock.now < deadline else { throw FixtureError.timedOut }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  private enum FixtureError: Error { case timedOut, noRequest, saveFailed }
  private enum RecoveryMode: Sendable {
    case journaled, attachmentFails, heldQuery, heldReconnect, heldTerminalAcknowledgement
    case cancelledJournal, cancellingResident
    case windowMoved, windowKeepsMoving
  }

  private actor MemoryStore: AgentConversationStoring {
    var archive: AgentConversationArchive?
    let failAfterSequence: UInt64?
    init(failAfterSequence: UInt64? = nil) { self.failAfterSequence = failAfterSequence }
    func load() async throws -> AgentConversationArchive? { archive }
    func save(_ archive: AgentConversationArchive) async throws {
      try validateForPersistence(archive)
      if let failAfterSequence,
        archive.conversations.contains(where: {
          ($0.history?.exchanges.last?.lastEventSequence ?? 0) >= failAfterSequence
        })
      {
        throw FixtureError.saveFailed
      }
      self.archive = archive
    }
    nonisolated func validateForPersistence(_ archive: AgentConversationArchive) throws {
      try AgentConversationStore.validateForPersistence(archive)
    }
  }

  private actor DeliveryClient: HexAgentClient {
    let gatewayID = GatewayInstanceID()
    let invocationID = GatewayRunInvocationID(rawValue: UUID())
    let failureCode: GatewayFailureCode
    let mode: RecoveryMode
    let failFirstRunTerminally: Bool
    let refuseFirstForMaintenance: Bool
    private(set) var connectCount = 0
    private(set) var cancelCount = 0
    private(set) var reattachCount = 0
    private(set) var startRequests: [GatewayStartRunRequest] = []
    private(set) var recoveryRequests: [GatewayRunRecoveryRequest] = []
    private var records: [AgentEventRecord] = []
    private var queryWaiter: CheckedContinuation<Void, Never>?
    private var connectionWaiter: CheckedContinuation<Void, Never>?
    private var terminalAcknowledgementWaiter: CheckedContinuation<Void, Never>?
    private var cancellationStream:
      AsyncThrowingStream<GatewayEventEnvelope, any Error>.Continuation?
    var isQueryHeld: Bool { queryWaiter != nil }
    var isConnectionHeld: Bool { connectionWaiter != nil }
    var isTerminalAcknowledgementHeld: Bool { terminalAcknowledgementWaiter != nil }

    init(
      failureCode: GatewayFailureCode, mode: RecoveryMode = .journaled,
      failFirstRunTerminally: Bool = false, refuseFirstForMaintenance: Bool = false
    ) {
      self.failureCode = failureCode
      self.mode = mode
      self.failFirstRunTerminally = failFirstRunTerminally
      self.refuseFirstForMaintenance = refuseFirstForMaintenance
    }
    func connect() async throws -> GatewayConnectionResult {
      connectCount += 1
      if mode == .heldReconnect, connectCount == 2 {
        await withCheckedContinuation { connectionWaiter = $0 }
      }
      return GatewayConnectionResult(
        response: GatewayHandshakeResponse(
          sessionID: GatewaySessionID(), gatewayInstanceID: gatewayID,
          selectedVersion: .current, activeRun: nil), previousGatewayInstanceID: nil)
    }
    func disconnect() async throws {
      releaseQuery()
      releaseConnection()
      releaseTerminalAcknowledgement()
    }
    func startRun(_ request: GatewayStartRunRequest) async throws -> GatewayStartRunResponse {
      startRequests.append(request)
      if refuseFirstForMaintenance, startRequests.count == 1 {
        throw GatewayFailure(
          code: .toolMaintenanceInProgress, message: "Tool check in progress.", isRetryable: true)
      }
      let user = try #require(request.initialMessages.last)
      let events: [AgentEvent]
      if failFirstRunTerminally, startRequests.count == 1 {
        events = [
          .runStarted, .messageAppended(user),
          .runFailed(
            AgentFailure(
              code: .invalidState, message: "Retryable fixture failure.", isRetryable: true)),
        ]
      } else if mode == .cancelledJournal || mode == .cancellingResident {
        events = [
          .runStarted, .messageAppended(user), .inferenceEvent(.textDelta("Hel")),
          .inferenceEvent(.textDelta("lo")), .runCancelled,
        ]
      } else {
        events = [
          .runStarted, .messageAppended(user), .inferenceEvent(.textDelta("Hel")),
          .inferenceEvent(.textDelta("lo")),
          .messageAppended(Message(role: .assistant, content: [.text("Hello")])), .runCompleted,
        ]
      }
      records = events.enumerated().map {
        AgentEventRecord(
          id: AgentEventID(), runID: request.runID, sequence: UInt64($0.offset + 1),
          timestamp: Date(), event: $0.element)
      }
      return GatewayStartRunResponse(
        runID: request.runID, disposition: .started(invocationID: invocationID))
    }
    func eventRecords(for runID: AgentRunID, invocationID: GatewayRunInvocationID) async throws
      -> AsyncThrowingStream<GatewayEventEnvelope, any Error>
    {
      if failureCode == .replayUnavailable {
        throw GatewayFailure(
          code: .replayUnavailable,
          message: "Initial events advanced beyond the replay window before attachment.")
      }
      let pair = AsyncThrowingStream<GatewayEventEnvelope, any Error>.makeStream()
      for record in records.prefix(3) {
        pair.continuation.yield(GatewayEventEnvelope(invocationID: invocationID, record: record))
      }
      if mode == .cancelledJournal || mode == .cancellingResident {
        cancellationStream = pair.continuation
      } else {
        pair.continuation.finish(
          throwing: GatewayFailure(
            code: failureCode, message: "Delivery interrupted.", isRetryable: true))
      }
      return pair.stream
    }
    func recoverRun(_ request: GatewayRunRecoveryRequest) async throws -> GatewayRunRecoveryResponse
    {
      recoveryRequests.append(request)
      if mode == .heldQuery { await withCheckedContinuation { queryWaiter = $0 } }
      let first = try #require(records.first)
      let disposition: GatewayRunRecoveryDisposition
      if mode == .attachmentFails || mode == .heldTerminalAcknowledgement
        || mode == .cancellingResident
        || mode == .windowKeepsMoving || mode == .windowMoved && recoveryRequests.count == 1
      {
        disposition = .resident(
          snapshot: GatewayRunSnapshot(
            runID: request.runID, invocationID: invocationID, phase: .running, latestSequence: 3),
          minimumReplaySequence: 0,
          journal: mode == .windowMoved || mode == .windowKeepsMoving
            ? GatewayJournalRunSnapshot(
              runID: request.runID, firstEventID: first.id, latestSequence: 3, terminalRecord: nil)
            : nil)
      } else {
        disposition = .journaled(
          GatewayJournalRunSnapshot(
            runID: request.runID, firstEventID: first.id,
            latestSequence: try #require(records.last?.sequence),
            terminalRecord: records.last))
      }
      return GatewayRunRecoveryResponse(
        gatewayInstanceID: gatewayID, runID: request.runID, disposition: disposition)
    }
    func readRunHistory(_ request: GatewayRunHistoryRequest) async throws -> GatewayRunHistoryPage {
      GatewayRunHistoryPage(
        gatewayInstanceID: gatewayID, runID: request.runID, firstEventID: request.firstEventID,
        afterSequence: request.afterSequence, throughSequence: request.throughSequence,
        records: records.filter { $0.sequence > request.afterSequence }, nextAfterSequence: nil)
    }
    func eventRecords(
      for runID: AgentRunID, invocationID: GatewayRunInvocationID, afterSequence: UInt64
    )
      async throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error>
    {
      reattachCount += 1
      if mode == .windowMoved || mode == .windowKeepsMoving {
        throw GatewayFailure(code: .invalidCursor, message: "Live replay advanced during catch-up.")
      }
      if mode == .cancellingResident {
        let pair = AsyncThrowingStream<GatewayEventEnvelope, any Error>.makeStream()
        for record in records where record.sequence > afterSequence && record.sequence < 5 {
          pair.continuation.yield(GatewayEventEnvelope(invocationID: invocationID, record: record))
        }
        cancellationStream = pair.continuation
        return pair.stream
      }
      if mode == .heldTerminalAcknowledgement {
        let pair = AsyncThrowingStream<GatewayEventEnvelope, any Error>.makeStream()
        for record in records where record.sequence > afterSequence {
          pair.continuation.yield(GatewayEventEnvelope(invocationID: invocationID, record: record))
        }
        pair.continuation.finish()
        return pair.stream
      }
      throw GatewayFailure(
        code: .consumerTooSlow, message: "Attachment interrupted.", isRetryable: true)
    }
    func shouldApply(_ envelope: GatewayEventEnvelope) async throws -> Bool { true }
    func acknowledge(_ envelope: GatewayEventEnvelope) async throws {
      if mode == .heldTerminalAcknowledgement, envelope.record.sequence == 6 {
        await withCheckedContinuation { terminalAcknowledgementWaiter = $0 }
      }
    }
    func decideAuthorization(_ request: AuthorizationRequest, choice: AuthorizationDecisionChoice)
      async throws
    {}
    func cancelRun(_ request: GatewayCancelRunRequest) async throws -> GatewayCancelRunResponse {
      cancelCount += 1
      cancellationStream?.finish(
        throwing: GatewayFailure(
          code: failureCode, message: "Delivery interrupted after cancellation.", isRetryable: true)
      )
      cancellationStream = nil
      return GatewayCancelRunResponse(
        runID: request.runID, invocationID: request.invocationID, disposition: .requested)
    }
    func releaseCancellationTerminal() {
      if let terminal = records.last {
        cancellationStream?.yield(
          GatewayEventEnvelope(invocationID: invocationID, record: terminal))
      }
      cancellationStream?.finish()
      cancellationStream = nil
    }
    func releaseQuery() {
      queryWaiter?.resume()
      queryWaiter = nil
    }
    func releaseConnection() {
      connectionWaiter?.resume()
      connectionWaiter = nil
    }
    func releaseTerminalAcknowledgement() {
      terminalAcknowledgementWaiter?.resume()
      terminalAcknowledgementWaiter = nil
    }
  }
}
