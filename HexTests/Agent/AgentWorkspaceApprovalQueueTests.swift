import Foundation
import HexCore
import HexIPC
import Testing

@testable import Hex

@Suite("Workspace ordered approval queue")
struct AgentWorkspaceApprovalQueueTests {
  @Test @MainActor
  func cancellationKeepsReplayedApprovalsAsEvidenceWithoutOfferingAnotherDecision() async throws {
    let (model, client, runID) = try await fixture()
    defer { model.runTask?.cancel() }
    let first = authorization(runID: runID, resource: "first.swift")
    let second = authorization(runID: runID, resource: "second.swift")
    try await emit([.authorizationRequested(first)], to: client)
    model.cancel()
    try await emit([.authorizationRequested(second)], to: client)
    #expect(model.runState == .cancelling)
    #expect(model.pendingAuthorizations == [first, second])
    #expect(model.pendingAuthorization == nil)
    model.decideAuthorization(.allowOnce)
    #expect(await client.submissions.isEmpty)
    await finish(model, client: client)
    #expect(model.runState == .cancelled)
    #expect(model.pendingAuthorizations.isEmpty)
  }

  @Test @MainActor
  func concurrentRequestsPresentTheOldestWithoutAutomaticallyDecidingEither() async throws {
    let (model, client, runID) = try await fixture()
    defer { model.runTask?.cancel() }
    let first = authorization(runID: runID, resource: "first.swift")
    let second = authorization(runID: runID, resource: "second.swift")

    try await emit([.authorizationRequested(first), .authorizationRequested(second)], to: client)

    #expect(model.pendingAuthorization == first)
    #expect(model.runState == .waitingForAuthorization)
    #expect(!model.isSubmittingAuthorization)
    #expect(await client.submissions.isEmpty)
    await finish(model, client: client)
  }

  @Test(arguments: [AuthorizationDecisionChoice.allowOnce, .deny]) @MainActor
  func successfulDecisionAdvancesOnlyTheSelectedRequest(_ choice: AuthorizationDecisionChoice)
    async throws
  {
    let (model, client, runID) = try await fixture()
    defer { model.runTask?.cancel() }
    let first = authorization(runID: runID, resource: "first.swift")
    let second = authorization(runID: runID, resource: "second.swift")
    try await emit([.authorizationRequested(first), .authorizationRequested(second)], to: client)

    model.decideAuthorization(choice)
    try await waitUntil {
      await client.submissions.count == 1 && !model.isSubmittingAuthorization
    }

    #expect(await client.submissions == [Submission(request: first, choice: choice)])
    #expect(model.pendingAuthorization == second)
    #expect(model.runState == .waitingForAuthorization)
    #expect(model.errorMessage == nil)

    // A successful submission hides the first request until its durable decision arrives;
    // that later decision must not clear the next displayed request.
    let recordedDecision: AuthorizationDecision = choice == .deny ? .deny(reason: nil) : .allow
    try await emit(
      [.authorizationDecided(requestID: first.id, decision: recordedDecision)], to: client)
    #expect(model.pendingAuthorization == second)
    #expect(model.runState == .waitingForAuthorization)
    #expect(await client.submissions.count == 1)
    await finish(model, client: client)
  }

  @Test(arguments: [SubmissionBehavior.failure, .cancelled]) @MainActor
  func failedOrCancelledSubmissionRetainsTheFirstRequestAndDoesNotDecideTheNext(
    _ behavior: SubmissionBehavior
  ) async throws {
    let (model, client, runID) = try await fixture(behavior: behavior)
    defer { model.runTask?.cancel() }
    let first = authorization(runID: runID, resource: "first.swift")
    let second = authorization(runID: runID, resource: "second.swift")
    try await emit([.authorizationRequested(first), .authorizationRequested(second)], to: client)

    model.decideAuthorization(.allowOnce)
    try await waitUntil {
      await client.submissions.count == 1 && !model.isSubmittingAuthorization
    }

    #expect(await client.submissions == [Submission(request: first, choice: .allowOnce)])
    #expect(model.pendingAuthorization == first)
    #expect(model.runState == .waitingForAuthorization)
    if behavior == .failure { #expect(model.errorMessage != nil) }
    await finish(model, client: client)
  }

  @Test @MainActor
  func recordedDecisionsRemoveOnlyTheirExactRequestIdentity() async throws {
    let (model, client, runID) = try await fixture()
    defer { model.runTask?.cancel() }
    let first = authorization(runID: runID, resource: "first.swift")
    let second = authorization(runID: runID, resource: "second.swift")
    let third = authorization(runID: runID, resource: "third.swift")
    let unknown = authorization(runID: runID, resource: "unknown.swift")
    try await emit(
      [
        .authorizationRequested(first), .authorizationRequested(second),
        .authorizationRequested(third),
      ], to: client)

    try await emit(
      [.authorizationDecided(requestID: second.id, decision: .deny(reason: "Declined elsewhere"))],
      to: client)
    #expect(model.pendingAuthorization == first)
    #expect(model.runState == .waitingForAuthorization)

    try await emit(
      [
        .authorizationDecided(requestID: second.id, decision: .deny(reason: "Declined elsewhere")),
        .authorizationDecided(requestID: unknown.id, decision: .allow),
      ], to: client)
    #expect(model.pendingAuthorization == first)
    #expect(model.runState == .waitingForAuthorization)

    try await emit([.authorizationDecided(requestID: first.id, decision: .allow)], to: client)
    #expect(model.pendingAuthorization == third)
    #expect(model.runState == .waitingForAuthorization)
    #expect(await client.submissions.isEmpty)
    await finish(model, client: client)
  }

  @Test @MainActor
  func arrivingRequestDoesNotUnlockAnExistingSubmission() async throws {
    let (model, client, runID) = try await fixture(behavior: .suspended)
    defer { model.runTask?.cancel() }
    let first = authorization(runID: runID, resource: "first.swift")
    let second = authorization(runID: runID, resource: "second.swift")
    try await emit([.authorizationRequested(first)], to: client)
    model.decideAuthorization(.allowOnce)
    try await waitUntil { await client.submissions.count == 1 }

    try await emit([.authorizationRequested(second)], to: client)

    #expect(model.isSubmittingAuthorization)
    #expect(model.pendingAuthorization == first)
    #expect(await client.submissions == [Submission(request: first, choice: .allowOnce)])
    try await client.completeSubmission(at: 0)
    try await waitUntil { !model.isSubmittingAuthorization }
    #expect(model.pendingAuthorization == second)
    await finish(model, client: client)
  }

  @Test @MainActor
  func lateCompletionCannotClearANewerSubmission() async throws {
    let (model, client, runID) = try await fixture(behavior: .suspended)
    defer { model.runTask?.cancel() }
    let first = authorization(runID: runID, resource: "first.swift")
    let second = authorization(runID: runID, resource: "second.swift")
    try await emit([.authorizationRequested(first), .authorizationRequested(second)], to: client)
    model.decideAuthorization(.allowOnce)
    try await waitUntil { await client.submissions.count == 1 }
    try await emit([.authorizationDecided(requestID: first.id, decision: .allow)], to: client)
    #expect(model.pendingAuthorization == second)
    #expect(!model.isSubmittingAuthorization)

    model.decideAuthorization(.deny)
    try await waitUntil { await client.submissions.count == 2 }
    #expect(model.isSubmittingAuthorization)
    try await client.completeSubmission(at: 0)
    // Allow the deliberately delayed first RPC's MainActor completion to run while the second
    // RPC remains gated. This does not depend on network, UI rendering, or provider timing.
    try await Task.sleep(for: .milliseconds(20))

    #expect(model.isSubmittingAuthorization)
    #expect(model.pendingAuthorization == second)
    #expect(
      await client.submissions == [
        Submission(request: first, choice: .allowOnce), Submission(request: second, choice: .deny),
      ])
    try await client.completeSubmission(at: 1)
    try await waitUntil { !model.isSubmittingAuthorization }
    #expect(model.pendingAuthorization == nil)
    await finish(model, client: client)
  }

  @MainActor
  private func fixture(behavior: SubmissionBehavior = .success) async throws -> (
    AgentWorkspaceModel, ApprovalClient, AgentRunID
  ) {
    let client = ApprovalClient(behavior: behavior)
    let model = AgentWorkspaceModel(
      client: client, modelID: "fixture-model", conversationStore: nil)
    await model.connect()
    model.draft = "Inspect the requested files"
    model.send()
    do { try await waitUntil { await client.isObserving } } catch {
      model.runTask?.cancel()
      await model.runTask?.value
      throw error
    }
    return (model, client, try #require(model.currentRunID))
  }

  private func authorization(runID: AgentRunID, resource: String) -> AuthorizationRequest {
    AuthorizationRequest(
      runID: runID, capability: CapabilityID(rawValue: "filesystem.read"),
      operation: "read", resource: resource, explanation: "Inspect one requested file.")
  }

  @MainActor
  private func emit(_ events: [AgentEvent], to client: ApprovalClient) async throws {
    let sequence = try await client.emit(events)
    // An acknowledgement follows model application; no sleep-based guess about UI readiness.
    try await waitUntil { await client.acknowledgedSequence >= sequence }
  }

  @MainActor
  private func finish(_ model: AgentWorkspaceModel, client: ApprovalClient) async {
    let task = model.runTask
    await client.finish()
    await task?.value
  }

  @MainActor
  private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
    for _ in 0..<100 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await condition())
    throw FixtureError.conditionNotMet
  }

  enum SubmissionBehavior: Equatable, Sendable {
    case success, failure, cancelled, suspended
  }

  private enum FixtureError: Error {
    case conditionNotMet, streamNotAttached, submissionFailed
  }

  private struct Submission: Equatable, Sendable {
    let request: AuthorizationRequest
    let choice: AuthorizationDecisionChoice
  }

  private actor ApprovalClient: HexAgentClient {
    let behavior: SubmissionBehavior
    var runID: AgentRunID?
    let invocationID = GatewayRunInvocationID(rawValue: UUID())
    var continuation: AsyncThrowingStream<GatewayEventEnvelope, any Error>.Continuation?
    var sequence: UInt64 = 0
    private(set) var acknowledgedSequence: UInt64 = 0
    private(set) var submissions: [Submission] = []
    var pendingSubmissions: [Int: CheckedContinuation<Void, any Error>] = [:]
    var isObserving: Bool { continuation != nil }

    init(behavior: SubmissionBehavior) { self.behavior = behavior }

    func connect() async throws -> GatewayConnectionResult {
      GatewayConnectionResult(
        response: GatewayHandshakeResponse(
          sessionID: GatewaySessionID(), gatewayInstanceID: GatewayInstanceID(),
          selectedVersion: .current, activeRun: nil), previousGatewayInstanceID: nil)
    }

    func disconnect() async throws {}

    func startRun(_ request: GatewayStartRunRequest) async throws -> GatewayStartRunResponse {
      runID = request.runID
      return GatewayStartRunResponse(
        runID: request.runID, disposition: .started(invocationID: invocationID))
    }

    func eventRecords(for runID: AgentRunID, invocationID: GatewayRunInvocationID) async throws
      -> AsyncThrowingStream<GatewayEventEnvelope, any Error>
    {
      guard self.runID == runID, self.invocationID == invocationID else {
        throw FixtureError.streamNotAttached
      }
      let pair = AsyncThrowingStream<GatewayEventEnvelope, any Error>.makeStream()
      continuation = pair.continuation
      return pair.stream
    }

    func emit(_ events: [AgentEvent]) throws -> UInt64 {
      guard let continuation, let runID else { throw FixtureError.streamNotAttached }
      for event in events {
        sequence += 1
        continuation.yield(
          GatewayEventEnvelope(
            invocationID: invocationID,
            record: AgentEventRecord(
              id: AgentEventID(), runID: runID, sequence: sequence, timestamp: Date(), event: event)
          ))
      }
      return sequence
    }

    func finish() {
      for pending in pendingSubmissions.values { pending.resume(throwing: CancellationError()) }
      pendingSubmissions.removeAll()
      _ = try? emit([.runCancelled])
      continuation?.finish()
      continuation = nil
    }

    func cancelRun(_ request: GatewayCancelRunRequest) async throws -> GatewayCancelRunResponse {
      GatewayCancelRunResponse(
        runID: request.runID, invocationID: request.invocationID, disposition: .requested)
    }

    func shouldApply(_ envelope: GatewayEventEnvelope) async throws -> Bool { true }
    func acknowledge(_ envelope: GatewayEventEnvelope) async throws {
      acknowledgedSequence = envelope.record.sequence
    }

    func decideAuthorization(_ request: AuthorizationRequest, choice: AuthorizationDecisionChoice)
      async throws
    {
      let index = submissions.count
      submissions.append(Submission(request: request, choice: choice))
      switch behavior {
      case .success: return
      case .failure: throw FixtureError.submissionFailed
      case .cancelled: throw CancellationError()
      case .suspended:
        try await withCheckedThrowingContinuation { pendingSubmissions[index] = $0 }
      }
    }

    func completeSubmission(at index: Int) throws {
      guard let pending = pendingSubmissions.removeValue(forKey: index) else {
        throw FixtureError.conditionNotMet
      }
      pending.resume()
    }
  }
}
