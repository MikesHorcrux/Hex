import Foundation
import HexCore
import HexIPC
import Testing

@testable import Hex

@Suite("Workspace cancellation response ownership")
struct AgentWorkspaceCancellationRaceTests {
  @Test @MainActor
  func lateCancellationFailureCannotReplaceConfirmedCompletion() async throws {
    let client = CancellationClient()
    let model = AgentWorkspaceModel(client: client, conversationStore: nil)
    await model.connect()
    model.draft = "Finish or cancel once"
    model.send()
    do {
      try await waitUntil { await client.streamCount == 1 && model.runState == .running }
      let request = try #require(await client.requests.first)
      model.cancel()
      try await waitUntil { await client.isCancellationBlocked }
      await client.finish(request.runID)
      await model.runTask?.value
      #expect(model.runState == .completed)
      await client.failBlockedCancellation()
      try await waitUntil { await client.cancellationFailureReturned }
      try await Task.sleep(for: .milliseconds(20))
      #expect(model.runState == .completed)
      #expect(model.errorMessage == nil)
      #expect(model.transcript.filter { $0.role == .assistant }.map(\.text) == ["Finished"])
      #expect(await client.requests.count == 1)
      #expect(await client.cancellationRequests.count == 1)
    } catch {
      await client.cleanup()
      model.runTask?.cancel()
      throw error
    }
    await client.cleanup()
  }

  @Test @MainActor
  func lateCancellationFailureCannotFailANewerRun() async throws {
    let client = CancellationClient()
    let model = AgentWorkspaceModel(client: client, conversationStore: nil)
    await model.connect()
    model.draft = "First task"
    model.send()
    do {
      try await waitUntil { await client.streamCount == 1 && model.runState == .running }
      let first = try #require(await client.requests.first)
      model.cancel()
      try await waitUntil { await client.isCancellationBlocked }

      await client.finish(first.runID)
      await model.runTask?.value
      #expect(model.runState == .completed)
      model.draft = "Second task"
      model.send()
      try await waitUntil { await client.streamCount == 2 && model.runState == .running }
      let second = try #require(await client.requests.last)
      #expect(first.runID != second.runID)
      #expect(model.currentRunID == second.runID)
      #expect(model.errorMessage == nil)

      await client.failBlockedCancellation()
      try await waitUntil { await client.cancellationFailureReturned }
      // The held client call has returned; allow the MainActor's error continuation to run.
      try await Task.sleep(for: .milliseconds(20))
      #expect(model.currentRunID == second.runID)
      #expect(model.runState == .running)
      #expect(model.errorMessage == nil)
      #expect(model.isRunActive)
      #expect(await client.cancellationRequests.map(\.runID) == [first.runID])
      #expect(await client.requests.count == 2)

      await client.finish(second.runID)
      await model.runTask?.value
      #expect(model.runState == .completed)
    } catch {
      await client.cleanup()
      model.runTask?.cancel()
      throw error
    }
    await client.cleanup()
  }

  @MainActor
  private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
    for _ in 0..<200 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw FixtureError.timedOut
  }

  private enum FixtureError: Error { case timedOut, wrongInvocation, cancellationFailed }

  private actor CancellationClient: HexAgentClient {
    private let gateway = GatewayInstanceID()
    private var invocations: [AgentRunID: GatewayRunInvocationID] = [:]
    private var streams:
      [AgentRunID: AsyncThrowingStream<GatewayEventEnvelope, any Error>.Continuation] = [:]
    private var sequences: [AgentRunID: UInt64] = [:]
    private var blockedCancellation: CheckedContinuation<Void, Never>?
    private(set) var requests: [GatewayStartRunRequest] = []
    private(set) var cancellationRequests: [GatewayCancelRunRequest] = []
    private(set) var streamCount = 0
    private(set) var cancellationFailureReturned = false
    var isCancellationBlocked: Bool { blockedCancellation != nil }

    func connect() async throws -> GatewayConnectionResult {
      GatewayConnectionResult(
        response: GatewayHandshakeResponse(
          sessionID: GatewaySessionID(), gatewayInstanceID: gateway,
          selectedVersion: .current, activeRun: nil), previousGatewayInstanceID: nil)
    }

    func disconnect() async throws {}

    func startRun(_ request: GatewayStartRunRequest) async throws -> GatewayStartRunResponse {
      requests.append(request)
      let invocation = GatewayRunInvocationID(rawValue: UUID())
      invocations[request.runID] = invocation
      return GatewayStartRunResponse(
        runID: request.runID, disposition: .started(invocationID: invocation))
    }

    func eventRecords(for runID: AgentRunID, invocationID: GatewayRunInvocationID) async throws
      -> AsyncThrowingStream<GatewayEventEnvelope, any Error>
    {
      guard invocations[runID] == invocationID,
        let request = requests.first(where: { $0.runID == runID })
      else { throw FixtureError.wrongInvocation }
      let (stream, continuation) = AsyncThrowingStream<GatewayEventEnvelope, any Error>.makeStream()
      streams[runID] = continuation
      streamCount += 1
      emit(.runStarted, for: runID)
      for message in request.initialMessages { emit(.messageAppended(message), for: runID) }
      return stream
    }

    func cancelRun(_ request: GatewayCancelRunRequest) async throws -> GatewayCancelRunResponse {
      cancellationRequests.append(request)
      await withCheckedContinuation { blockedCancellation = $0 }
      cancellationFailureReturned = true
      throw FixtureError.cancellationFailed
    }

    func failBlockedCancellation() {
      blockedCancellation?.resume()
      blockedCancellation = nil
    }

    func finish(_ runID: AgentRunID) {
      emit(.messageAppended(Message(role: .assistant, content: [.text("Finished")])), for: runID)
      emit(.runCompleted, for: runID)
      streams.removeValue(forKey: runID)?.finish()
    }

    func cleanup() {
      failBlockedCancellation()
      for stream in streams.values { stream.finish(throwing: CancellationError()) }
      streams.removeAll()
    }

    private func emit(_ event: AgentEvent, for runID: AgentRunID) {
      guard let invocation = invocations[runID], let stream = streams[runID] else { return }
      let sequence = (sequences[runID] ?? 0) + 1
      sequences[runID] = sequence
      stream.yield(
        GatewayEventEnvelope(
          invocationID: invocation,
          record: AgentEventRecord(
            id: AgentEventID(), runID: runID, sequence: sequence, timestamp: Date(), event: event)))
    }

    func shouldApply(_ envelope: GatewayEventEnvelope) async throws -> Bool { true }
    func acknowledge(_ envelope: GatewayEventEnvelope) async throws {}
    func decideAuthorization(_ request: AuthorizationRequest, choice: AuthorizationDecisionChoice)
      async throws
    {}
  }
}
