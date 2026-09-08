import Foundation
import HexCore
import Testing

@testable import HexIPC

@Suite("Gateway service driver shutdown")
struct GatewayShutdownTests {
  @Test
  func waitsForCancelledDriverToFinishBeforeFinalizingSessions() async throws {
    let driver = GatedDriver()
    let service = HexGatewayService(driver: driver)
    let session = try await service.handshake(GatewayTestValues.handshakeRequest())
    let runID = GatewayTestValues.runID()
    try await start(runID, service: service, sessionID: session.sessionID, driver: driver)

    let shutdown = Task { try await service.shutdown() }
    try await waitUntil { await driver.wasCancelled(runID) }
    try await waitUntil { await service.drainWaiters.count == 1 }
    #expect(await service.sessions.count == 1)
    #expect(await service.liveDriverTasks.count == 1)
    #expect(await service.runs[runID]?.terminalSequence == nil)

    await driver.release(runID)
    try await shutdown.value
    #expect(await driver.didReturn(runID))
    #expect(await service.liveDriverTasks.isEmpty)
    #expect(await service.drainWaiters.isEmpty)
    #expect(await service.sessions.isEmpty)
    #expect(await service.runs[runID]?.terminalSequence == 2)
    try await service.shutdown(timeout: .zero)
  }

  @Test
  func timeoutKeepsOwnershipAndCanBeDrainedLater() async throws {
    let driver = GatedDriver()
    let service = HexGatewayService(driver: driver)
    let session = try await service.handshake(GatewayTestValues.handshakeRequest())
    let runID = GatewayTestValues.runID()
    try await start(runID, service: service, sessionID: session.sessionID, driver: driver)

    let clock = ContinuousClock()
    let began = clock.now
    do {
      try await service.shutdown(timeout: .milliseconds(20))
      Issue.record("A noncooperative driver must prevent successful shutdown.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .transportUnavailable)
      #expect(failure.isRetryable)
    }
    #expect(began.duration(to: clock.now) < .seconds(2))
    #expect(await service.liveDriverTasks.count == 1)
    #expect(await service.drainWaiters.isEmpty)
    #expect(await service.sessions.count == 1)
    #expect(await service.shutdownFinalized == false)

    await driver.release(runID)
    try await service.shutdown()
    #expect(await driver.didReturn(runID))
    #expect(await service.liveDriverTasks.isEmpty)
    #expect(await service.sessions.isEmpty)
  }

  @Test
  func keepsTerminalDriverOwnedAfterItsReplayHasBeenEvicted() async throws {
    let driver = GatedDriver()
    let service = HexGatewayService(driver: driver, configuration: try smallConfiguration())
    let session = try await service.handshake(GatewayTestValues.handshakeRequest())
    let first = GatewayTestValues.runID(1)
    try await start(first, service: service, sessionID: session.sessionID, driver: driver)
    try await driver.emitTerminal(first)

    for number: UInt8 in [2, 3] {
      let next = GatewayTestValues.runID(number)
      try await start(next, service: service, sessionID: session.sessionID, driver: driver)
      try await driver.emitTerminal(next)
      await driver.release(next)
      try await waitUntil { await service.liveDriverTasks.count == 1 }
    }
    #expect(await service.runs[first] == nil)
    #expect(await service.liveDriverTasks.count == 1)
    await service.beginShutdown()
    try await waitUntil { await driver.wasCancelled(first) }
    do {
      try await service.drainRuns(timeout: .zero)
      Issue.record("An evicted replay entry must not release its still-live driver.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .transportUnavailable)
    }
    await driver.release(first)
    try await service.shutdown()
    #expect(await driver.didReturn(first))
    #expect(await service.liveDriverTasks.isEmpty)
  }

  @Test
  func boundsTerminalButStillLiveDriversWithoutEvictingTheirOwnership() async throws {
    let driver = GatedDriver()
    let service = HexGatewayService(driver: driver, configuration: try smallConfiguration())
    let session = try await service.handshake(GatewayTestValues.handshakeRequest())
    for number: UInt8 in [1, 2] {
      let runID = GatewayTestValues.runID(number)
      try await start(runID, service: service, sessionID: session.sessionID, driver: driver)
      try await driver.emitTerminal(runID)
    }
    do {
      _ = try await service.startRun(
        GatewayTestValues.request(runID: GatewayTestValues.runID(3)), sessionID: session.sessionID)
      Issue.record("Live driver ownership must be bounded independently of replay eviction.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .capacityExceeded)
      #expect(failure.isRetryable)
    }
    #expect(await service.liveDriverTasks.count == 2)
    #expect(await service.runs.count == 2)
    await driver.release(GatewayTestValues.runID(1))
    await driver.release(GatewayTestValues.runID(2))
    try await service.shutdown()
  }

  @Test
  func concurrentAndAlreadyCancelledCallersStillAwaitCleanup() async throws {
    let driver = GatedDriver()
    let service = HexGatewayService(driver: driver)
    let session = try await service.handshake(GatewayTestValues.handshakeRequest())
    let runID = GatewayTestValues.runID()
    try await start(runID, service: service, sessionID: session.sessionID, driver: driver)

    let first = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await service.shutdown()
    }
    let second = Task { try await service.shutdown() }
    try await waitUntil { await service.drainWaiters.count == 2 }
    second.cancel()
    #expect(await service.sessions.count == 1)
    #expect(await service.liveDriverTasks.count == 1)
    await driver.release(runID)
    try await first.value
    try await second.value
    #expect(await service.drainWaiters.isEmpty)
    #expect(await service.sessions.isEmpty)
    try await service.shutdown()
  }

  @Test
  func sealsNewAdmissionsButKeepsExistingRecoveryUntilFinalShutdown() async throws {
    let driver = GatedDriver()
    let service = HexGatewayService(driver: driver)
    let session = try await service.handshake(GatewayTestValues.handshakeRequest())
    let runID = GatewayTestValues.runID()
    try await start(runID, service: service, sessionID: session.sessionID, driver: driver)
    await service.beginShutdown()
    do {
      _ = try await service.handshake(GatewayTestValues.handshakeRequest(20))
      Issue.record("Shutdown must seal new sessions.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .transportUnavailable)
    }
    for number: UInt8 in [1, 2] {
      do {
        _ = try await service.startRun(
          GatewayTestValues.request(runID: GatewayTestValues.runID(number)),
          sessionID: session.sessionID)
        Issue.record("Shutdown must reject both duplicate and new start requests.")
      } catch let failure as GatewayFailure {
        #expect(failure.code == .transportUnavailable)
      }
    }
    let recovery = try await service.recoverRun(
      GatewayRunRecoveryRequest(runID: runID), sessionID: session.sessionID)
    guard case .resident(let snapshot, _, _) = recovery.disposition else {
      Issue.record("Existing recovery sessions must remain usable during drain.")
      await driver.release(runID)
      try await service.shutdown()
      return
    }
    #expect(snapshot.phase == .cancelling)
    await driver.release(runID)
    try await service.drainRuns()
    #expect(await service.sessions.count == 1)
    _ = try await service.recoverRun(
      GatewayRunRecoveryRequest(runID: runID), sessionID: session.sessionID)
    try await service.shutdown()
    do {
      _ = try await service.recoverRun(
        GatewayRunRecoveryRequest(runID: runID), sessionID: session.sessionID)
      Issue.record("Final shutdown must revoke existing sessions.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .staleSession)
    }
  }

  private func smallConfiguration() throws -> GatewayConfiguration {
    try #require(
      GatewayConfiguration(
        maximumWireBytes: 32_768, maximumRetainedRecordsPerRun: 2,
        subscriberBufferCapacity: 2, maximumRememberedRuns: 2))
  }

  private func start(
    _ runID: AgentRunID, service: HexGatewayService, sessionID: GatewaySessionID,
    driver: GatedDriver
  ) async throws {
    let result = try await service.startRun(
      GatewayTestValues.request(runID: runID), sessionID: sessionID)
    _ = try #require(result.invocationID)
    try await waitUntil { await driver.isWaiting(runID) }
  }

  private func waitUntil(_ predicate: @Sendable () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !(await predicate()) {
      guard clock.now < deadline else { throw WaitFailure.timedOut }
      await Task.yield()
    }
  }

  private enum WaitFailure: Error { case timedOut }

  /// Deliberately keeps ownership after cancellation and after a terminal event until released.
  private actor GatedDriver: HexGatewayRunDriver {
    private var gates: [AgentRunID: CheckedContinuation<Void, Never>] = [:]
    private var emitters: [AgentRunID: @Sendable (AgentEventRecord) async throws -> Void] = [:]
    private var cancelled: Set<AgentRunID> = []
    private var terminal: Set<AgentRunID> = []
    private var returned: Set<AgentRunID> = []

    func run(
      _ request: GatewayStartRunRequest,
      emit: @escaping @Sendable (AgentEventRecord) async throws -> Void
    ) async throws {
      let runID = request.runID
      defer { returned.insert(runID) }
      try await emit(GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted))
      emitters[runID] = emit
      await withTaskCancellationHandler {
        await withCheckedContinuation { gates[runID] = $0 }
      } onCancel: {
        Task { await self.recordCancellation(runID) }
      }
      if !terminal.contains(runID) {
        let event: AgentEvent = Task.isCancelled ? .runCancelled : .runCompleted
        try await emit(GatewayTestValues.record(runID: runID, sequence: 2, event: event))
      }
      emitters.removeValue(forKey: runID)
      try Task.checkCancellation()
    }

    func emitTerminal(_ runID: AgentRunID) async throws {
      let emit = try #require(emitters[runID])
      terminal.insert(runID)
      try await emit(GatewayTestValues.record(runID: runID, sequence: 2, event: .runCompleted))
    }

    func release(_ runID: AgentRunID) { gates.removeValue(forKey: runID)?.resume() }
    func isWaiting(_ runID: AgentRunID) -> Bool { gates[runID] != nil }
    func wasCancelled(_ runID: AgentRunID) -> Bool { cancelled.contains(runID) }
    func didReturn(_ runID: AgentRunID) -> Bool { returned.contains(runID) }
    private func recordCancellation(_ runID: AgentRunID) { cancelled.insert(runID) }
  }
}
