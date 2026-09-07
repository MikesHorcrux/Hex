import Foundation
import HexCore
import HexIPC
import Testing

@testable import Hex

@Suite("Resident activation reconnects chat once")
struct HexResidentActivationConnectionTests {
  @Test @MainActor
  func enablingAfterFailedInitialConnectionReconnectsAndClearsOldError() async throws {
    let client = SpyClient(failures: 1)
    let workspace = AgentWorkspaceModel(client: client)
    await workspace.connectAutomatically()
    #expect(workspace.connectionState == .disconnected)
    #expect(workspace.errorMessage != nil)
    let controller = LifecycleController()
    let activation = HexStartAtLoginModel(
      controller: controller, readinessChecker: ReadinessChecker(),
      onBecameReady: { await workspace.residentGatewayBecameReady() })
    await activation.refresh()
    activation.toggle()
    try await waitForUpdate(activation)

    #expect(workspace.connectionState == .connected)
    #expect(workspace.errorMessage == nil)
    #expect(await client.connectCount == 2)
    #expect(await controller.registerCount == 1)
    await activation.refresh()
    await activation.refresh()
    #expect(await client.connectCount == 2)
    #expect(await controller.registerCount == 1)
  }

  @Test @MainActor
  func approvalAndReadinessMustBothBeSatisfiedBeforeTheOneAttempt() async {
    let client = SpyClient(failures: 1)
    let workspace = AgentWorkspaceModel(client: client)
    let controller = LifecycleController(status: .requiresApproval)
    let readiness = ReadinessChecker(value: .blocked)
    let activation = HexStartAtLoginModel(
      controller: controller, readinessChecker: readiness,
      onBecameReady: { await workspace.residentGatewayBecameReady() })
    await activation.refresh()
    await controller.setStatus(.enabled)
    await activation.refresh()
    #expect(await client.connectCount == 0)
    await readiness.setReady()
    await activation.refresh()
    #expect(await client.connectCount == 1)
    #expect(workspace.connectionState == .disconnected)
    await activation.refresh()
    #expect(await client.connectCount == 1)
    #expect(await controller.registerCount == 0)
  }

  @Test @MainActor
  func explicitDisconnectSuppressesActivationAndWindowAutomaticConnection() async {
    let client = SpyClient()
    let workspace = AgentWorkspaceModel(client: client)
    await workspace.connect()
    await workspace.disconnect()
    await workspace.residentGatewayBecameReady()
    await workspace.connectAutomatically()
    #expect(workspace.connectionState == .disconnected)
    #expect(await client.connectCount == 1)
    await workspace.connect()
    #expect(workspace.connectionState == .connected)
    #expect(await client.connectCount == 2)
  }

  @Test(arguments: [false, true]) @MainActor
  func restartReplacesTheOldConnectionWithoutReversingExplicitDisconnect(disconnected: Bool) async {
    let client = SpyClient()
    let workspace = AgentWorkspaceModel(client: client)
    await workspace.connect()
    if disconnected { await workspace.disconnect() }
    let controller = LifecycleController(status: .enabled)
    let activation = HexStartAtLoginModel(
      controller: controller, readinessChecker: ReadinessChecker(),
      onConnectionReset: { workspace.markGatewayDisconnected() },
      onBecameReady: { await workspace.residentGatewayBecameReady() })
    await activation.refresh()
    #expect(await client.connectCount == 1)

    await activation.restart()

    #expect(activation.message == nil)
    #expect(workspace.connectionState == (disconnected ? .disconnected : .connected))
    #expect(await client.connectCount == (disconnected ? 1 : 2))
    await activation.refresh()
    #expect(await client.connectCount == (disconnected ? 1 : 2))
    #expect(await client.startCount == 0)
  }

  @Test @MainActor
  func failedRestartClearsOldConnectedStateAndDoesNotReportReady() async {
    let client = SpyClient()
    let workspace = AgentWorkspaceModel(client: client)
    await workspace.connect()
    let controller = LifecycleController(status: .enabled, failsRegistration: true)
    let activation = HexStartAtLoginModel(
      controller: controller, readinessChecker: ReadinessChecker(),
      onConnectionReset: { workspace.markGatewayDisconnected() },
      onBecameReady: { await workspace.residentGatewayBecameReady() })
    await activation.refresh()

    await activation.restart()

    #expect(activation.message != nil)
    #expect(workspace.connectionState == .disconnected)
    #expect(await client.connectCount == 1)
    #expect(await client.startCount == 0)
  }

  @Test @MainActor
  func activationDoesNotReplaceActiveWorkButRecoversPendingWorkWithoutResending() async throws {
    let client = SpyClient()
    let workspace = AgentWorkspaceModel(client: client)
    let request = GatewayStartRunRequest(
      runID: AgentRunID(), modelID: ModelID(rawValue: "preview"),
      initialMessages: [Message(role: .user, content: [.text("Original task")])])
    workspace.currentRunID = request.runID
    workspace.currentRunRequest = request
    workspace.runState = .running
    await workspace.residentGatewayBecameReady()
    #expect(await client.connectCount == 0)
    #expect(workspace.currentRunRequest == request)
    workspace.runState = .failed
    workspace.isRecoveringRun = true
    await workspace.residentGatewayBecameReady()
    #expect(await client.connectCount == 0)
    workspace.isRecoveringRun = false
    workspace.needsRunRecovery = true
    await workspace.residentGatewayBecameReady()
    await workspace.runTask?.value
    #expect(await client.connectCount == 1)
    #expect(await client.recoveredRunIDs == [request.runID])
    #expect(await client.startCount == 0)
    #expect(workspace.currentRunRequest == request)
  }

  @Test @MainActor
  func activationDuringAnEarlierConnectionQueuesOnlyOneRetryAfterItsFailure() async {
    let client = SpyClient(failures: 2, holdFirstConnection: true)
    let workspace = AgentWorkspaceModel(client: client)
    let first = Task { await workspace.connectAutomatically() }
    await client.waitForHeldConnection()
    await workspace.residentGatewayBecameReady()
    await workspace.residentGatewayBecameReady()
    #expect(await client.connectCount == 1)
    await client.releaseConnection()
    await first.value
    #expect(await client.connectCount == 2)
    #expect(workspace.connectionState == .disconnected)
    #expect(workspace.errorMessage != nil)
  }

  @Test @MainActor
  func explicitDisconnectCancelsPendingActivationReconnectIntent() async {
    let client = SpyClient(holdFirstConnection: true)
    let workspace = AgentWorkspaceModel(client: client)
    let first = Task { await workspace.connectAutomatically() }
    await client.waitForHeldConnection()
    await workspace.residentGatewayBecameReady()
    await workspace.disconnect()
    await client.releaseConnection()
    await first.value
    #expect(await client.connectCount == 1)
    #expect(workspace.connectionState == .disconnected)
    await workspace.connectAutomatically()
    #expect(await client.connectCount == 1)
  }

  @MainActor
  private func waitForUpdate(_ model: HexStartAtLoginModel) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while model.isUpdating {
      guard clock.now < deadline else { throw FixtureFailure.timedOut }
      await Task.yield()
    }
  }

  private enum FixtureFailure: Error { case timedOut, failedRegistration }

  private actor LifecycleController: HexGatewayLifecycleControlling {
    var value: HexGatewayLifecycleStatus
    private let failsRegistration: Bool
    private(set) var registerCount = 0
    init(status: HexGatewayLifecycleStatus = .notRegistered, failsRegistration: Bool = false) {
      value = status
      self.failsRegistration = failsRegistration
    }
    func status() async -> HexGatewayLifecycleStatus { value }
    func register() async throws {
      if failsRegistration { throw FixtureFailure.failedRegistration }
      registerCount += 1
      value = .enabled
    }
    func unregister() async throws { value = .notRegistered }
    func setStatus(_ status: HexGatewayLifecycleStatus) { value = status }
  }

  private actor ReadinessChecker: HexGatewayActivationReadinessChecking {
    var value: HexGatewayActivationReadiness
    init(value: HexGatewayActivationReadiness = .ready) { self.value = value }
    func check() async -> HexGatewayActivationReadiness { value }
    func setReady() { value = .ready }
  }

  private actor SpyClient: HexAgentClient {
    private let preview = PreviewHexAgentClient()
    private var failures: Int
    private let holdFirstConnection: Bool
    private var held: CheckedContinuation<Void, Never>?
    private var entered: [CheckedContinuation<Void, Never>] = []
    private(set) var connectCount = 0
    private(set) var startCount = 0
    private(set) var recoveredRunIDs: [AgentRunID] = []

    init(failures: Int = 0, holdFirstConnection: Bool = false) {
      self.failures = failures
      self.holdFirstConnection = holdFirstConnection
    }
    func connect() async throws -> GatewayConnectionResult {
      connectCount += 1
      if holdFirstConnection && connectCount == 1 {
        await withCheckedContinuation { continuation in
          held = continuation
          for waiter in entered { waiter.resume() }
          entered.removeAll()
        }
      }
      if failures > 0 {
        failures -= 1
        throw GatewayFailure(
          code: .transportUnavailable, message: "Fixture unavailable", isRetryable: true)
      }
      return try await preview.connect()
    }
    func disconnect() async throws { try await preview.disconnect() }
    func availableModels() async throws -> [ModelDescriptor] { try await preview.availableModels() }
    func startRun(_ request: GatewayStartRunRequest) async throws -> GatewayStartRunResponse {
      startCount += 1
      return try await preview.startRun(request)
    }
    func eventRecords(for runID: AgentRunID, invocationID: GatewayRunInvocationID) async throws
      -> AsyncThrowingStream<GatewayEventEnvelope, any Error>
    { try await preview.eventRecords(for: runID, invocationID: invocationID) }
    func cancelRun(_ request: GatewayCancelRunRequest) async throws -> GatewayCancelRunResponse {
      try await preview.cancelRun(request)
    }
    func shouldApply(_ envelope: GatewayEventEnvelope) async throws -> Bool { true }
    func acknowledge(_ envelope: GatewayEventEnvelope) async throws {}
    func decideAuthorization(_ request: AuthorizationRequest, choice: AuthorizationDecisionChoice)
      async throws
    {}
    func recoverRun(_ request: GatewayRunRecoveryRequest) async throws -> GatewayRunRecoveryResponse
    {
      recoveredRunIDs.append(request.runID)
      throw GatewayFailure(code: .runNotFound, message: "Fixture has no journal")
    }
    func waitForHeldConnection() async {
      if held != nil { return }
      await withCheckedContinuation { entered.append($0) }
    }
    func releaseConnection() {
      held?.resume()
      held = nil
    }
  }
}
