import Foundation
import HexCapabilities
import HexCore
import Testing
import os

@Suite("Native Accessibility dispatch boundaries")
struct MacAccessibilityDispatchSafetyTests {
  @Test
  func cancellationDuringTrustCheckNeverDispatchesAnAction() async throws {
    let controller = Controller(cancelsDuringTrustCheck: true)
    let observations = MacAccessibilityObservationLedger()
    let tool = MacAccessibilityActionTool(
      controller: controller, observationLedger: observations, sessionState: { .available })
    let context = ToolExecutionContext(runID: AgentRunID())
    let snapshot = try await controller.snapshot(
      bundleIdentifier: "com.hex.fixture", maximumDepth: 2, maximumElements: 10)
    try await observations.record(snapshot, runID: context.runID)
    let call = actionCall(observationID: snapshot.observationID)
    _ = try await tool.authorizationRequest(for: call, in: context)
    let task = Task { try await tool.execute(call, in: context) }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await controller.actions == 0)
  }

  @Test
  func dispatchAcknowledgementDoesNotClaimVisibleVerification() async throws {
    let controller = Controller()
    let observations = MacAccessibilityObservationLedger()
    let tool = MacAccessibilityActionTool(
      controller: controller, observationLedger: observations, sessionState: { .available })
    let context = ToolExecutionContext(runID: AgentRunID())
    let snapshot = try await controller.snapshot(
      bundleIdentifier: "com.hex.fixture", maximumDepth: 2, maximumElements: 10)
    try await observations.record(snapshot, runID: context.runID)
    let call = actionCall(observationID: snapshot.observationID)
    _ = try await tool.authorizationRequest(for: call, in: context)
    let result = try await tool.execute(call, in: context)
    guard case .object(let output) = result.output else {
      Issue.record("An Accessibility receipt must be structured.")
      return
    }
    #expect(output["dispatched"] == .boolean(true))
    #expect(output["outcome_verified"] == .boolean(false))
    #expect(await controller.promptRequests == [false])
  }

  @Test(arguments: [MacInteractionSessionState.locked, .unavailable])
  func blockedSessionNeverDispatches(state: MacInteractionSessionState) async throws {
    let controller = Controller()
    let observations = MacAccessibilityObservationLedger()
    let tool = MacAccessibilityActionTool(
      controller: controller, observationLedger: observations, sessionState: { state })
    let context = ToolExecutionContext(runID: AgentRunID())
    let snapshot = try await controller.snapshot(
      bundleIdentifier: "com.hex.fixture", maximumDepth: 2, maximumElements: 10)
    try await observations.record(snapshot, runID: context.runID)
    let call = actionCall(observationID: snapshot.observationID)
    _ = try await tool.authorizationRequest(for: call, in: context)
    let result = try await tool.execute(call, in: context)
    #expect(result.status == .failure)
    #expect(result.requiresUserAttention)
    #expect(await controller.actions == 0)
    #expect(await controller.promptRequests.isEmpty)
  }

  @Test
  func sessionLockDuringPermissionAwaitPreventsDispatch() async throws {
    let session = OSAllocatedUnfairLock(initialState: MacInteractionSessionState.available)
    let controller = Controller(onTrustCheck: { session.withLock { $0 = .locked } })
    let observations = MacAccessibilityObservationLedger()
    let tool = MacAccessibilityActionTool(
      controller: controller, observationLedger: observations,
      sessionState: { session.withLock { $0 } })
    let context = ToolExecutionContext(runID: AgentRunID())
    let snapshot = try await controller.snapshot(
      bundleIdentifier: "com.hex.fixture", maximumDepth: 2, maximumElements: 10)
    try await observations.record(snapshot, runID: context.runID)
    let call = actionCall(observationID: snapshot.observationID)
    _ = try await tool.authorizationRequest(for: call, in: context)
    let result = try await tool.execute(call, in: context)
    guard case .object(let output) = result.output else {
      Issue.record("Missing receipt")
      return
    }
    #expect(output["error"] == .string("mac_session_locked"))
    #expect(output["dispatched"] == .boolean(false))
    #expect(await controller.actions == 0)
  }

  @Test
  func uncertainDispatchCannotRepeatUntilNewObservation() async throws {
    let controller = Controller(actionError: .accessibilityActionOutcomeUnknown)
    let observations = MacAccessibilityObservationLedger()
    let tool = MacAccessibilityActionTool(
      controller: controller, observationLedger: observations, sessionState: { .available })
    let context = ToolExecutionContext(runID: AgentRunID())
    let snapshot = try await controller.snapshot(
      bundleIdentifier: "com.hex.fixture", maximumDepth: 2, maximumElements: 10)
    try await observations.record(snapshot, runID: context.runID)
    let call = actionCall(observationID: snapshot.observationID)
    _ = try await tool.authorizationRequest(for: call, in: context)
    let result = try await tool.execute(call, in: context)
    guard case .object(let output) = result.output else {
      Issue.record("Missing receipt")
      return
    }
    #expect(output["error"] == .string("accessibility_action_outcome_unknown"))
    #expect(output["dispatched"] == .boolean(true))
    #expect(output["outcome_unknown"] == .boolean(true))
    #expect(output["outcome_verified"] == .boolean(false))
    #expect(result.requiresUserAttention)
    let repeatCall = actionCall(observationID: snapshot.observationID)
    _ = try await tool.authorizationRequest(for: repeatCall, in: context)
    let repeated = try await tool.execute(repeatCall, in: context)
    guard case .object(let repeatedOutput) = repeated.output else {
      Issue.record("Missing refusal receipt")
      return
    }
    #expect(repeatedOutput["error"] == .string("accessibility_observation_stale"))
    #expect(repeatedOutput["dispatched"] == .boolean(false))
    #expect(await controller.actions == 1)
  }

  @Test
  func staleObservationAtExecutionStopsAuthorizedAction() async throws {
    let controller = Controller()
    let observations = MacAccessibilityObservationLedger()
    let tool = MacAccessibilityActionTool(
      controller: controller, observationLedger: observations, sessionState: { .available })
    let context = ToolExecutionContext(runID: AgentRunID())
    let snapshot = try await controller.snapshot(
      bundleIdentifier: "com.hex.fixture", maximumDepth: 2, maximumElements: 10)
    try await observations.record(snapshot, runID: context.runID)
    let call = actionCall(observationID: snapshot.observationID)
    _ = try await tool.authorizationRequest(for: call, in: context)
    let replacement = try await controller.snapshot(
      bundleIdentifier: "com.hex.fixture", maximumDepth: 2, maximumElements: 10)
    try await observations.record(replacement, runID: context.runID)
    let result = try await tool.execute(call, in: context)
    guard case .object(let output) = result.output else {
      Issue.record("Missing receipt")
      return
    }
    #expect(output["error"] == .string("accessibility_observation_stale"))
    #expect(output["dispatched"] == .boolean(false))
    #expect(!result.requiresUserAttention)
    #expect(await controller.actions == 0)
  }

  private func actionCall(observationID: String) -> ToolCall {
    ToolCall(
      name: "mac_accessibility_action",
      arguments: [
        "observation_id": .string(observationID),
        "bundle_id": .string("com.hex.fixture"), "path": .string("0.1"), "action": .string("press"),
      ])
  }

  private actor Controller: MacAccessibilityControlling {
    let cancelsDuringTrustCheck: Bool
    let actionError: MacToolError?
    let onTrustCheck: @Sendable () -> Void
    private(set) var actions = 0
    private(set) var promptRequests: [Bool] = []

    init(
      cancelsDuringTrustCheck: Bool = false, actionError: MacToolError? = nil,
      onTrustCheck: @escaping @Sendable () -> Void = {}
    ) {
      self.cancelsDuringTrustCheck = cancelsDuringTrustCheck
      self.actionError = actionError
      self.onTrustCheck = onTrustCheck
    }

    func isTrusted(promptIfNeeded: Bool) -> Bool {
      promptRequests.append(promptIfNeeded)
      onTrustCheck()
      if cancelsDuringTrustCheck { withUnsafeCurrentTask { $0?.cancel() } }
      return true
    }

    func snapshot(bundleIdentifier: String, maximumDepth: Int, maximumElements: Int)
      throws -> MacAccessibilitySnapshot
    {
      MacAccessibilitySnapshot(
        bundleIdentifier: bundleIdentifier, applicationName: "Fixture", processIdentifier: 42,
        elements: [.init(path: "0.1", role: "AXButton", title: "Apply", actions: ["AXPress"])],
        isTruncated: false)
    }

    func perform(_ request: MacAccessibilityActionRequest) throws -> MacAccessibilityActionResult {
      actions += 1
      if let actionError { throw actionError }
      return MacAccessibilityActionResult(
        bundleIdentifier: request.bundleIdentifier, path: "0.1", action: request.action,
        observationID: request.observationID)
    }
  }
}
