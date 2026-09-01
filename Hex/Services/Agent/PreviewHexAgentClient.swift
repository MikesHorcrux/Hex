import Foundation
import HexCore
import HexIPC

/// A deterministic in-memory client used by the app default and SwiftUI previews. It emits the
/// same gateway event shapes as a real run, pauses at one exact authorization request, and never
/// reads credentials or touches the filesystem.
actor PreviewHexAgentClient: HexAgentClient {
  private let gatewayInstanceID = GatewayInstanceID()
  private var sessionID: GatewaySessionID?
  private var connected = false
  private var streams: [AgentRunID: AsyncThrowingStream<GatewayEventEnvelope, any Error>] = [:]
  private var continuations:
    [AgentRunID: AsyncThrowingStream<GatewayEventEnvelope, any Error>.Continuation] = [:]
  private var invocationIDs: [AgentRunID: GatewayRunInvocationID] = [:]
  private var sequences: [AgentRunID: UInt64] = [:]
  private var producerTasks: [AgentRunID: Task<Void, Never>] = [:]
  private var terminalRunIDs: Set<AgentRunID> = []
  private var cancelledRunIDs: Set<AgentRunID> = []
  private var pendingAuthorization: [AgentRunID: AuthorizationRequest] = [:]
  private var authorizationWaiters:
    [AuthorizationRequestID: CheckedContinuation<AuthorizationDecisionChoice, Never>] = [:]

  func connect() async throws -> GatewayConnectionResult {
    let previousGatewayInstanceID = connected ? gatewayInstanceID : nil
    let sessionID = self.sessionID ?? GatewaySessionID()
    self.sessionID = sessionID
    connected = true

    let response = GatewayHandshakeResponse(
      sessionID: sessionID,
      gatewayInstanceID: gatewayInstanceID,
      selectedVersion: .current,
      activeRun: nil
    )
    return GatewayConnectionResult(
      response: response,
      previousGatewayInstanceID: previousGatewayInstanceID
    )
  }

  func disconnect() async throws {
    connected = false
    for task in producerTasks.values {
      task.cancel()
    }
    producerTasks.removeAll()
    for waiter in authorizationWaiters.values {
      waiter.resume(returning: .deny)
    }
    authorizationWaiters.removeAll()
    pendingAuthorization.removeAll()
    for continuation in continuations.values {
      continuation.finish(
        throwing: GatewayFailure(
          code: .disconnected,
          message: "The preview gateway session was disconnected.",
          isRetryable: true
        )
      )
    }
    continuations.removeAll()
    streams.removeAll()
    invocationIDs.removeAll()
    sequences.removeAll()
    terminalRunIDs.removeAll()
    cancelledRunIDs.removeAll()
    sessionID = nil
  }

  func startRun(_ request: GatewayStartRunRequest) async throws -> GatewayStartRunResponse {
    guard connected, sessionID != nil else {
      throw GatewayFailure(
        code: .notConnected,
        message: "The preview gateway is not connected.",
        isRetryable: true
      )
    }
    if let invocationID = invocationIDs[request.runID] {
      let disposition: GatewayStartRunDisposition =
        terminalRunIDs.contains(request.runID)
        ? .alreadyTerminal(invocationID: invocationID)
        : .alreadyRunning(invocationID: invocationID)
      return GatewayStartRunResponse(runID: request.runID, disposition: disposition)
    }

    let invocationID = GatewayRunInvocationID(rawValue: UUID())
    let pair = AsyncThrowingStream<GatewayEventEnvelope, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(32)
    )
    invocationIDs[request.runID] = invocationID
    sequences[request.runID] = 0
    streams[request.runID] = pair.stream
    continuations[request.runID] = pair.continuation

    let producerTask = Task { [weak self] in
      guard let self else { return }
      await self.produce(request, invocationID: invocationID)
    }
    producerTasks[request.runID] = producerTask
    return GatewayStartRunResponse(
      runID: request.runID,
      disposition: .started(invocationID: invocationID)
    )
  }

  func eventRecords(
    for runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) async throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error> {
    guard connected else {
      throw GatewayFailure(
        code: .notConnected,
        message: "The preview gateway is not connected.",
        isRetryable: true
      )
    }
    guard invocationIDs[runID] == invocationID, let stream = streams[runID] else {
      throw GatewayFailure(
        code: .runNotFound,
        message: "The preview run is no longer available."
      )
    }
    return stream
  }

  func cancelRun(_ request: GatewayCancelRunRequest) async throws -> GatewayCancelRunResponse {
    guard invocationIDs[request.runID] == request.invocationID else {
      return GatewayCancelRunResponse(
        runID: request.runID,
        invocationID: request.invocationID,
        disposition: .notFound
      )
    }
    guard !terminalRunIDs.contains(request.runID) else {
      return GatewayCancelRunResponse(
        runID: request.runID,
        invocationID: request.invocationID,
        disposition: .alreadyTerminal
      )
    }

    cancelledRunIDs.insert(request.runID)
    if let authorization = pendingAuthorization.removeValue(forKey: request.runID),
      let waiter = authorizationWaiters.removeValue(forKey: authorization.id)
    {
      waiter.resume(returning: .deny)
    }
    producerTasks[request.runID]?.cancel()
    return GatewayCancelRunResponse(
      runID: request.runID,
      invocationID: request.invocationID,
      disposition: .requested
    )
  }

  func shouldApply(_ envelope: GatewayEventEnvelope) async throws -> Bool {
    true
  }

  func acknowledge(_ envelope: GatewayEventEnvelope) async throws {}

  func decideAuthorization(
    _ request: AuthorizationRequest,
    choice: AuthorizationDecisionChoice
  ) async throws {
    guard pendingAuthorization[request.runID]?.id == request.id else {
      throw GatewayFailure(
        code: .runNotFound,
        message: "This authorization request is no longer pending."
      )
    }
    guard let waiter = authorizationWaiters.removeValue(forKey: request.id) else {
      throw GatewayFailure(
        code: .supersededOperation,
        message: "The authorization request was already answered."
      )
    }
    pendingAuthorization.removeValue(forKey: request.runID)
    waiter.resume(returning: choice)
  }

  private func produce(
    _ request: GatewayStartRunRequest,
    invocationID: GatewayRunInvocationID
  ) async {
    let runID = request.runID
    do {
      try await emit(.runStarted, runID: runID, invocationID: invocationID)
      for message in request.initialMessages {
        try await emit(.messageAppended(message), runID: runID, invocationID: invocationID)
      }
      try await pause()

      let inferenceRequest = InferenceRequest(
        providerID: ProviderID(rawValue: "preview"),
        modelID: request.modelID,
        messages: request.initialMessages,
        toolChoice: request.toolChoice,
        options: request.options
      )
      try await emit(
        .inferenceRequested(inferenceRequest),
        runID: runID,
        invocationID: invocationID
      )
      try await emit(
        .inferenceEvent(.started(providerResponseID: "preview-response")),
        runID: runID,
        invocationID: invocationID
      )
      try await emit(
        .inferenceEvent(
          .textDelta("I can help with that. Before I inspect the workspace, I need your approval.")),
        runID: runID,
        invocationID: invocationID
      )
      try await pause()

      let request = AuthorizationRequest(
        runID: runID,
        toolCallID: nil,
        capability: CapabilityID(rawValue: "filesystem.read"),
        operation: "List workspace files",
        resource: "/workspace",
        details: [
          "access": .string("read-only"),
          "purpose": .string("Inspect the project before answering"),
        ],
        explanation:
          "Hex wants to list the workspace so it can ground its answer in the project you selected."
      )
      pendingAuthorization[runID] = request
      try await emit(
        .authorizationRequested(request),
        runID: runID,
        invocationID: invocationID
      )

      let choice = await waitForAuthorization(request)
      if cancelledRunIDs.contains(runID) {
        throw CancellationError()
      }
      let decision: AuthorizationDecision =
        choice == .deny
        ? .deny(reason: "Denied by the operator.")
        : .allow
      try await emit(
        .authorizationDecided(requestID: request.id, decision: decision),
        runID: runID,
        invocationID: invocationID
      )

      let assistantText: String
      if choice == .deny {
        assistantText =
          "I’ll leave the workspace untouched. You can approve the read-only request whenever you’re ready to continue."
      } else {
        let call = ToolCall(
          name: "list_workspace",
          arguments: ["path": .string("/workspace")]
        )
        try await emit(.toolStarted(call), runID: runID, invocationID: invocationID)
        try await pause()
        let result = ToolResult(
          toolCallID: call.id,
          status: .success,
          output: .object([
            "entries": .array([.string("README.md"), .string("Sources")]),
            "count": .integer(2),
          ]),
          content: [.text("Found README.md and Sources.")]
        )
        try await emit(.toolFinished(result), runID: runID, invocationID: invocationID)
        assistantText =
          choice == .allowForSession
          ? "Read-only access is allowed for this session. I found README.md and Sources and can use them to continue."
          : "Read-only access was allowed once. I found README.md and Sources and can use them to continue."
      }

      try await emit(
        .inferenceEvent(.textDelta(assistantText)),
        runID: runID,
        invocationID: invocationID
      )
      try await emit(
        .inferenceEvent(.completed(.stop)),
        runID: runID,
        invocationID: invocationID
      )
      try await emit(
        .messageAppended(Message(role: .assistant, content: [.text(assistantText)])),
        runID: runID,
        invocationID: invocationID
      )
      try await emit(.runCompleted, runID: runID, invocationID: invocationID)
      finish(runID: runID)
    } catch is CancellationError {
      if !terminalRunIDs.contains(runID) {
        _ = emitUnchecked(.runCancelled, runID: runID, invocationID: invocationID)
        finish(runID: runID)
      }
    } catch {
      if !terminalRunIDs.contains(runID) {
        _ = emitUnchecked(
          .runFailed(
            AgentFailure(
              code: .transport,
              message: "The preview run failed unexpectedly."
            )
          ),
          runID: runID,
          invocationID: invocationID
        )
        finish(runID: runID)
      }
    }
    producerTasks.removeValue(forKey: runID)
  }

  private func waitForAuthorization(
    _ request: AuthorizationRequest
  ) async -> AuthorizationDecisionChoice {
    if cancelledRunIDs.contains(request.runID) {
      return .deny
    }
    return await withCheckedContinuation { continuation in
      authorizationWaiters[request.id] = continuation
    }
  }

  private func pause() async throws {
    try await Task.sleep(nanoseconds: 90_000_000)
  }

  private func emit(
    _ event: AgentEvent,
    runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) async throws {
    try Task.checkCancellation()
    guard !cancelledRunIDs.contains(runID) else {
      throw CancellationError()
    }
    guard emitUnchecked(event, runID: runID, invocationID: invocationID) else {
      throw GatewayFailure(
        code: .consumerTooSlow,
        message: "The preview consumer could not accept the event stream.",
        isRetryable: true
      )
    }
  }

  @discardableResult
  private func emitUnchecked(
    _ event: AgentEvent,
    runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) -> Bool {
    guard !terminalRunIDs.contains(runID), let continuation = continuations[runID] else {
      return false
    }
    let nextSequence = (sequences[runID] ?? 0) + 1
    sequences[runID] = nextSequence
    let record = AgentEventRecord(
      id: AgentEventID(),
      runID: runID,
      sequence: nextSequence,
      timestamp: Date(),
      event: event
    )
    switch continuation.yield(
      GatewayEventEnvelope(invocationID: invocationID, record: record)
    ) {
    case .enqueued:
      return true
    case .dropped, .terminated:
      return false
    @unknown default:
      return false
    }
  }

  private func finish(runID: AgentRunID) {
    terminalRunIDs.insert(runID)
    continuations[runID]?.finish()
  }
}
