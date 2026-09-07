import Foundation
import HexCore
import HexIPC
import Testing

@testable import Hex

@Suite("Agent workspace retry")
struct AgentWorkspaceRetryTests {
  @Test @MainActor
  func terminalRunFailurePreservesIntentWithoutDuplicatingPrompt() async throws {
    let client = RetryRecordingAgentClient()
    let model = AgentWorkspaceModel(
      client: client,
      modelID: "gpt-test",
      conversationStore: nil,
      defaultAuthorizationMode: .fullAccess
    )
    await model.connect()
    model.draft = "Inspect this project"

    model.send()
    try await waitUntil {
      let requestCount = await client.requestCount()
      return model.runState == .failed && requestCount == 1
    }

    let firstRequest = try #require(await client.requests().first)
    #expect(firstRequest.authorizationMode == .fullAccess)
    model.selectedComposerAuthorizationMode = .askEveryTime
    model.retryLastFailure()
    try await waitUntil {
      let requestCount = await client.requestCount()
      return model.runState == .completed && requestCount == 2
    }

    let requests = await client.requests()
    let retryRequest = try #require(requests.last)
    #expect(retryRequest.runID != firstRequest.runID)
    #expect(retryRequest.modelID == firstRequest.modelID)
    #expect(retryRequest.initialMessages == firstRequest.initialMessages)
    #expect(retryRequest.options == firstRequest.options)
    #expect(retryRequest.toolChoice == firstRequest.toolChoice)
    #expect(retryRequest.workingDirectory == firstRequest.workingDirectory)
    #expect(retryRequest.authorizationMode == .askEveryTime)
    #expect(model.errorMessage == nil)
    #expect(!model.canRetryLastFailure)
    #expect(
      model.transcript.filter {
        $0.role == .user && $0.text == "Inspect this project"
      }.count == 1
    )
  }

  @Test @MainActor
  func interruptedStreamAutomaticallyReusesRunIdentity() async throws {
    let client = RetryRecordingAgentClient(failsViaTransport: true)
    let model = AgentWorkspaceModel(
      client: client,
      modelID: "gpt-test",
      conversationStore: nil
    )
    await model.connect()
    model.draft = "Resume this safely"

    model.send()
    try await waitUntil {
      let requestCount = await client.requestCount()
      let recoveryCount = await client.recoveryCount()
      return model.runState == .completed && requestCount == 1 && recoveryCount == 1
    }

    let firstRequest = try #require(await client.requests().first)
    #expect(await client.requests() == [firstRequest])
    #expect(model.errorMessage == nil)
    #expect(!model.canRetryLastFailure)
    #expect(
      model.transcript.filter {
        $0.role == .user && $0.text == "Resume this safely"
      }.count == 1
    )
  }

  @Test @MainActor
  func nonRetryableRunFailureDoesNotExposeOrLaunchRetry() async throws {
    let client = RetryRecordingAgentClient(terminalFailureIsRetryable: false)
    let model = AgentWorkspaceModel(
      client: client,
      modelID: "gpt-test",
      conversationStore: nil
    )
    await model.connect()
    model.draft = "Invalid provider request"

    model.send()
    try await waitUntil {
      let requestCount = await client.requestCount()
      return model.runState == .failed && requestCount == 1
    }

    let failureMessage = model.errorMessage
    #expect(!model.canRetryLastFailure)
    model.retryLastFailure()
    try await Task.sleep(for: .milliseconds(20))

    #expect(await client.requestCount() == 1)
    #expect(model.errorMessage == failureMessage)
  }

  @MainActor
  private func waitUntil(
    _ condition: @escaping @MainActor () async -> Bool
  ) async throws {
    for _ in 0..<100 where !(await condition()) {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await condition())
  }

  private actor RetryRecordingAgentClient: HexAgentClient {
    private let failsViaTransport: Bool
    private let terminalFailureIsRetryable: Bool
    private var isConnected = false
    private var recordedRequests: [GatewayStartRunRequest] = []
    private var invocationIDs: [AgentRunID: GatewayRunInvocationID] = [:]
    private var eventRecordsCallCount = 0
    private let gatewayInstanceID = GatewayInstanceID()
    private var recordedRecoveries: [GatewayRunRecoveryRequest] = []

    init(
      failsViaTransport: Bool = false,
      terminalFailureIsRetryable: Bool = true
    ) {
      self.failsViaTransport = failsViaTransport
      self.terminalFailureIsRetryable = terminalFailureIsRetryable
    }

    func connect() async throws -> GatewayConnectionResult {
      isConnected = true
      return GatewayConnectionResult(
        response: GatewayHandshakeResponse(
          sessionID: GatewaySessionID(),
          gatewayInstanceID: gatewayInstanceID,
          selectedVersion: .current,
          activeRun: nil
        ),
        previousGatewayInstanceID: nil
      )
    }

    func disconnect() async throws {
      isConnected = false
    }

    func startRun(_ request: GatewayStartRunRequest) async throws -> GatewayStartRunResponse {
      guard isConnected else {
        throw GatewayFailure(code: .notConnected, message: "Not connected.")
      }
      recordedRequests.append(request)
      let invocationID = GatewayRunInvocationID(rawValue: UUID())
      invocationIDs[request.runID] = invocationID
      return GatewayStartRunResponse(
        runID: request.runID,
        disposition: .started(invocationID: invocationID)
      )
    }

    func eventRecords(
      for runID: AgentRunID,
      invocationID: GatewayRunInvocationID
    ) async throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error> {
      guard invocationIDs[runID] == invocationID else {
        throw GatewayFailure(code: .runNotFound, message: "Run not found.")
      }
      eventRecordsCallCount += 1
      if failsViaTransport && eventRecordsCallCount == 1 {
        throw GatewayFailure(
          code: .disconnected,
          message: "The event stream was interrupted.",
          isRetryable: true
        )
      }

      let request = recordedRequests.last(where: { $0.runID == runID })
      let events: [AgentEvent]
      if !failsViaTransport && eventRecordsCallCount == 1 {
        events = [
          .runFailed(
            AgentFailure(
              code: .provider,
              message: "Provider failed.",
              isRetryable: terminalFailureIsRetryable
            )
          )
        ]
      } else {
        events = (request?.initialMessages.map(AgentEvent.messageAppended) ?? []) + [.runCompleted]
      }
      return AsyncThrowingStream { continuation in
        for (index, event) in events.enumerated() {
          continuation.yield(
            GatewayEventEnvelope(
              invocationID: invocationID,
              record: AgentEventRecord(
                id: AgentEventID(),
                runID: runID,
                sequence: UInt64(index + 1),
                timestamp: Date(),
                event: event
              )
            )
          )
        }
        continuation.finish()
      }
    }

    func eventRecords(
      for runID: AgentRunID, invocationID: GatewayRunInvocationID, afterSequence: UInt64
    ) async throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error> {
      #expect(afterSequence == 0)
      return try await eventRecords(for: runID, invocationID: invocationID)
    }

    func recoverRun(_ request: GatewayRunRecoveryRequest) async throws -> GatewayRunRecoveryResponse
    {
      recordedRecoveries.append(request)
      let invocationID = try #require(invocationIDs[request.runID])
      return GatewayRunRecoveryResponse(
        gatewayInstanceID: gatewayInstanceID, runID: request.runID,
        disposition: .resident(
          snapshot: GatewayRunSnapshot(
            runID: request.runID, invocationID: invocationID, phase: .running, latestSequence: 0),
          minimumReplaySequence: 0, journal: nil))
    }

    func cancelRun(_ request: GatewayCancelRunRequest) async throws -> GatewayCancelRunResponse {
      GatewayCancelRunResponse(
        runID: request.runID,
        invocationID: request.invocationID,
        disposition: .alreadyTerminal
      )
    }

    func shouldApply(_ envelope: GatewayEventEnvelope) async throws -> Bool {
      true
    }

    func acknowledge(_ envelope: GatewayEventEnvelope) async throws {}

    func decideAuthorization(
      _ request: AuthorizationRequest,
      choice: AuthorizationDecisionChoice
    ) async throws {}

    func requests() -> [GatewayStartRunRequest] {
      recordedRequests
    }

    func requestCount() -> Int {
      recordedRequests.count
    }

    func recoveryCount() -> Int { recordedRecoveries.count }
  }
}
