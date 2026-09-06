import Foundation
import HexCore
import HexIPC
import Testing

@testable import Hex

@Suite("Saved never-started tool history")
struct AgentWorkspaceNonExecutionHistoryTests {
  @Test(arguments: FirstOutcome.allCases) @MainActor
  func nextPromptUsesDurableReceiptsButNeverTreatsAnUnknownActionAsResolved(
    firstOutcome: FirstOutcome
  ) async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("hex-not-run-history-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("history.json")
    let store = try AgentConversationStore(fileURL: fileURL)
    let client = BatchClient(firstOutcome: firstOutcome)
    let model = AgentWorkspaceModel(client: client, conversationStore: store)
    await model.restoreConversationHistory()
    await model.connect()
    model.draft = "Perform the two actions"
    model.send()
    await model.runTask?.value
    await model.conversationPersistenceTask?.value

    #expect(model.runState == .failed)
    #expect(model.currentRunHasToolEvidence)
    #expect(model.currentRunMayHaveToolEffects == (firstOutcome != .notRun))
    #expect(
      model.errorMessage?.contains("A tool action may already have happened")
        == (firstOutcome != .notRun))
    let originalRequest = try #require(await client.requests.first)
    #expect(await client.requests.count == 1)

    // A new real store owner decodes the saved history; no in-memory model snapshot is injected.
    let reopenedStore = try AgentConversationStore(fileURL: fileURL)
    let restored = AgentWorkspaceModel(client: client, conversationStore: reopenedStore)
    await restored.restoreConversationHistory()
    let conversation = try #require(
      restored.conversations.first { $0.id == restored.selectedConversationID })
    let nativeMessages = await client.nativeMessages
    #expect(conversation.contextMessages() == originalRequest.initialMessages + nativeMessages)
    #expect(conversation.hasUnresolvedHistory == (firstOutcome == .unknownStarted))
    let notRunRows = restored.transcript.filter {
      $0.role == .tool && $0.text.hasPrefix("Not run\n")
    }
    #expect(notRunRows.count == (firstOutcome == .notRun ? 2 : 1))
    #expect(notRunRows.contains { $0.toolCallID == ToolCallID(rawValue: "second") })
    #expect(!notRunRows.contains { $0.text.contains("Succeeded") || $0.text.contains("Failed ·") })

    await restored.connect()
    restored.draft = "Tell me what happened"
    restored.send()
    await restored.runTask?.value
    await restored.conversationPersistenceTask?.value
    if firstOutcome == .unknownStarted {
      #expect(await client.requests.count == 1)
      #expect(restored.draft == "Tell me what happened")
      #expect(restored.errorMessage?.contains("unresolved tool action") == true)
    } else {
      let requests = await client.requests
      #expect(requests.count == 2)
      let next = try #require(requests.last)
      #expect(next.runID != originalRequest.runID)
      #expect(Array(next.initialMessages.dropLast()) == conversation.contextMessages())
      #expect(next.initialMessages.last?.content == [.text("Tell me what happened")])
      #expect(restored.runState == .completed)
      #expect(restored.errorMessage == nil)
    }
  }

  @Test @MainActor
  func cancelledPendingApprovalIsRetiredBeforeItsNativeResultCheckpoint() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("hex-not-run-approval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("history.json")
    let store = try AgentConversationStore(fileURL: fileURL)
    let client = BatchClient(firstOutcome: .notRun, pausesCancellation: true)
    let model = AgentWorkspaceModel(client: client, conversationStore: store)
    await model.restoreConversationHistory()
    await model.connect()
    model.draft = "Ask before performing either action"
    model.send()
    do {
      try await waitUntil { model.pendingAuthorizations.count == 2 }
      let approvals = model.pendingAuthorizations
      let resultSequence = model.currentAppliedSequence + 2
      #expect(model.pendingAuthorization == approvals[0])
      model.decideAuthorization(.deny)
      try await waitUntil { model.submittedAuthorizationIDs.contains(approvals[0].id) }
      model.decideAuthorization(.deny)
      try await waitUntil { await client.isSubmissionHeld }
      let secondSubmission = try #require(model.authorizationSubmissionID)
      #expect(model.authorizationSubmittingRequestID == approvals[1].id)
      #expect(model.isSubmittingAuthorization)

      // Cancellation releases only the first receipt pair. The unrelated approval remains live;
      // a terminal event cannot hide an invalid intermediate snapshot by clearing the whole queue.
      model.cancel()
      try await waitUntil { model.currentAppliedSequence == resultSequence }
      await model.conversationPersistenceTask?.value
      #expect(model.pendingAuthorizations == [approvals[1]])
      #expect(model.pendingAuthorization == approvals[1])
      #expect(!model.submittedAuthorizationIDs.contains(approvals[0].id))
      #expect(model.authorizationSubmissionID == secondSubmission)
      #expect(model.authorizationSubmittingRequestID == approvals[1].id)
      #expect(model.isSubmittingAuthorization)
      #expect(model.runState == .cancelling)
      let reopenedStore = try AgentConversationStore(fileURL: fileURL)
      let archive = try #require(try await reopenedStore.load())
      let conversation = try #require(
        archive.conversations.first { $0.id == archive.selectedConversationID })
      let checkpoint = try #require(conversation.pendingRun)
      #expect(checkpoint.appliedSequence == resultSequence)
      #expect(checkpoint.pendingAuthorizations == [approvals[1]])
      let message = try #require(conversation.history?.exchanges.last?.messages.last)
      guard case .toolResult(let result) = message.content.first else {
        throw FixtureError.invalidReceipt
      }
      #expect(message.role == .tool)
      #expect(result.toolCallID == approvals[0].toolCallID)
      #expect(result.notExecutedReason == .cancelled)
      #expect(conversation.history?.exchanges.last?.outcome == .inProgress)
      #expect(conversation.hasUnresolvedHistory)
      try await reopenedStore.save(archive)

      await client.releaseSecondCancellationReceipt()
      try await waitUntil { model.currentAppliedSequence == resultSequence + 2 }
      #expect(model.pendingAuthorizations.isEmpty)
      #expect(model.submittedAuthorizationIDs.isEmpty)
      #expect(model.authorizationSubmissionID == nil)
      #expect(model.authorizationSubmittingRequestID == nil)
      #expect(!model.isSubmittingAuthorization)
      #expect(model.runState == .cancelling)
      await client.finishCancellation()
      await model.runTask?.value
      await model.conversationPersistenceTask?.value
      #expect(model.runState == .cancelled)
      #expect(model.pendingAuthorizations.isEmpty)
      let finalArchive = try #require(try await reopenedStore.load())
      let finalConversation = try #require(finalArchive.conversations.first)
      #expect(finalConversation.pendingRun == nil)
      #expect(!finalConversation.hasUnresolvedHistory)
    } catch {
      await client.stopStreaming()
      await model.runTask?.value
      throw error
    }
  }

  @MainActor
  private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()) {
      guard ContinuousClock.now < deadline else { throw FixtureError.eventTimedOut }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private enum FixtureError: Error { case invalidReceipt, eventTimedOut }

  enum FirstOutcome: String, CaseIterable, Sendable {
    case notRun, knownExecuted, unknownStarted
  }

  /// Only the gateway event source is scripted. Admission, event reduction, persistence, restore,
  /// rendering text, unresolved-action protection and the next request use the actual app model.
  private actor BatchClient: HexAgentClient {
    private let gatewayInstanceID = GatewayInstanceID()
    private let batchEvents: [AgentEvent]
    private let calls: [ToolCall]
    private let pausesCancellation: Bool
    private var heldContinuation: AsyncThrowingStream<GatewayEventEnvelope, any Error>.Continuation?
    private var heldRunID: AgentRunID?
    private var heldInvocationID: GatewayRunInvocationID?
    private var heldSequence: UInt64 = 0
    private var firstCancellationReceiptSent = false
    private var secondCancellationReceiptSent = false
    private var heldSubmission: CheckedContinuation<Void, any Error>?
    var isSubmissionHeld: Bool { heldSubmission != nil }
    let nativeMessages: [Message]
    private(set) var requests: [GatewayStartRunRequest] = []

    init(firstOutcome: FirstOutcome, pausesCancellation: Bool = false) {
      self.pausesCancellation = pausesCancellation
      let first = ToolCall(id: ToolCallID(rawValue: "first"), name: "inspect", arguments: [:])
      let second = ToolCall(id: ToolCallID(rawValue: "second"), name: "inspect", arguments: [:])
      calls = [first, second]
      let announced = Message(role: .assistant, content: [.toolCall(first), .toolCall(second)])
      var events: [AgentEvent] = [.messageAppended(announced)]
      if firstOutcome != .notRun { events.append(.toolStarted(first)) }
      if firstOutcome != .unknownStarted {
        let result = ToolResult(
          toolCallID: first.id, status: firstOutcome == .notRun ? .failure : .success,
          output: firstOutcome == .notRun ? .object(["error": .string("not_executed")]) : .null,
          notExecutedReason: firstOutcome == .notRun ? .runStopped : nil)
        events += [
          .toolFinished(result),
          .messageAppended(Message(role: .tool, content: [.toolResult(result)])),
        ]
      }
      let secondResult = ToolResult(
        toolCallID: second.id, status: .failure,
        output: .object(["error": .string("not_executed")]), notExecutedReason: .runStopped)
      events += [
        .toolFinished(secondResult),
        .messageAppended(Message(role: .tool, content: [.toolResult(secondResult)])),
        .runFailed(
          AgentFailure(code: .toolExecution, message: "The batch stopped.", isRetryable: true)),
      ]
      batchEvents = events
      nativeMessages = events.compactMap { event in
        guard case .messageAppended(let message) = event else { return nil }
        return message
      }
    }

    func connect() async throws -> GatewayConnectionResult {
      GatewayConnectionResult(
        response: GatewayHandshakeResponse(
          sessionID: GatewaySessionID(), gatewayInstanceID: gatewayInstanceID,
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
      let request = try #require(requests.last)
      if pausesCancellation {
        let pair = AsyncThrowingStream<GatewayEventEnvelope, any Error>.makeStream()
        heldContinuation = pair.continuation
        heldRunID = runID
        heldInvocationID = invocationID
        let announced = Message(role: .assistant, content: calls.map(MessageContent.toolCall))
        let approvals = calls.map { call in
          AuthorizationRequest(
            runID: runID, toolCallID: call.id,
            capability: CapabilityID(rawValue: "filesystem.read"), operation: "Inspect files",
            explanation: "Ask before inspecting the fixture.")
        }
        let events =
          [.runStarted] + request.initialMessages.map(AgentEvent.messageAppended)
          + [.messageAppended(announced)] + approvals.map(AgentEvent.authorizationRequested)
        for event in events { emitHeld(event) }
        return pair.stream
      }
      let suffix: [AgentEvent] =
        requests.count == 1
        ? batchEvents
        : [
          .messageAppended(Message(role: .assistant, content: [.text("Understood.")])),
          .runCompleted,
        ]
      let events = [.runStarted] + request.initialMessages.map(AgentEvent.messageAppended) + suffix
      return AsyncThrowingStream { continuation in
        for (index, event) in events.enumerated() {
          continuation.yield(
            GatewayEventEnvelope(
              invocationID: invocationID,
              record: AgentEventRecord(
                id: AgentEventID(), runID: runID, sequence: UInt64(index + 1),
                timestamp: Date(), event: event)))
        }
        continuation.finish()
      }
    }

    func cancelRun(_ request: GatewayCancelRunRequest) async throws -> GatewayCancelRunResponse {
      if pausesCancellation, request.runID == heldRunID,
        request.invocationID == heldInvocationID, !firstCancellationReceiptSent
      {
        firstCancellationReceiptSent = true
        emitCancelledReceipt(for: calls[0])
        return GatewayCancelRunResponse(
          runID: request.runID, invocationID: request.invocationID, disposition: .requested)
      }
      return GatewayCancelRunResponse(
        runID: request.runID, invocationID: request.invocationID, disposition: .alreadyTerminal)
    }

    func finishCancellation() {
      guard firstCancellationReceiptSent else {
        stopStreaming()
        return
      }
      releaseSecondCancellationReceipt()
      emitHeld(.runCancelled)
      stopStreaming()
    }

    func releaseSecondCancellationReceipt() {
      guard firstCancellationReceiptSent, !secondCancellationReceiptSent else { return }
      secondCancellationReceiptSent = true
      emitCancelledReceipt(for: calls[1])
    }

    func stopStreaming() {
      heldSubmission?.resume(throwing: CancellationError())
      heldSubmission = nil
      heldContinuation?.finish()
      heldContinuation = nil
    }

    private func emitCancelledReceipt(for call: ToolCall) {
      let result = ToolResult(
        toolCallID: call.id, status: .failure,
        output: .object(["error": .string("not_executed")]), notExecutedReason: .cancelled)
      emitHeld(.toolFinished(result))
      emitHeld(.messageAppended(Message(role: .tool, content: [.toolResult(result)])))
    }

    private func emitHeld(_ event: AgentEvent) {
      guard let heldRunID, let heldInvocationID else { return }
      heldSequence += 1
      heldContinuation?.yield(
        GatewayEventEnvelope(
          invocationID: heldInvocationID,
          record: AgentEventRecord(
            id: AgentEventID(), runID: heldRunID, sequence: heldSequence,
            timestamp: Date(), event: event)))
    }

    func shouldApply(_ envelope: GatewayEventEnvelope) async throws -> Bool { true }
    func acknowledge(_ envelope: GatewayEventEnvelope) async throws {}
    func decideAuthorization(_ request: AuthorizationRequest, choice: AuthorizationDecisionChoice)
      async throws
    {
      if pausesCancellation, request.toolCallID == calls[1].id {
        try await withCheckedThrowingContinuation { heldSubmission = $0 }
      }
    }
  }
}
