import Foundation
import HexCore
import Testing

@testable import HexIPC

@Suite("Gateway idle tool maintenance ownership")
struct GatewayToolMaintenanceTests {
  @Test
  func maintenanceRefusesNewRunsButRetainsExactDuplicateAndReadAccess() async throws {
    let gateway = HexGatewayService(driver: ImmediateGatewayRunDriver())
    let session = try await gateway.handshake(GatewayTestValues.handshakeRequest())
    let original = GatewayTestValues.request(runID: GatewayTestValues.runID(20))
    let started = try await gateway.startRun(original, sessionID: session.sessionID)
    try await waitUntil { await gateway.liveDriverTasks.isEmpty }
    let gate = Gate()
    let pending = Task { try await gateway.withIdleToolMaintenance { await gate.enter() } }
    try await waitUntil { await gate.entered }

    await expectFailure(.toolMaintenanceInProgress) {
      _ = try await gateway.startRun(
        GatewayTestValues.request(runID: GatewayTestValues.runID(21)), sessionID: session.sessionID)
    }
    #expect(await gateway.runs[GatewayTestValues.runID(21)] == nil)
    #expect(await gateway.liveDriverTasks.isEmpty)
    let duplicate = try await gateway.startRun(original, sessionID: session.sessionID)
    #expect(duplicate.invocationID == started.invocationID)
    _ = try await gateway.recoverRun(
      GatewayRunRecoveryRequest(runID: original.runID), sessionID: session.sessionID)
    await expectFailure(.toolMaintenanceInProgress) {
      try await gateway.withIdleToolMaintenance {
        _ = Issue.record("Concurrent maintenance was dispatched.")
      }
    }

    await gate.release()
    try await pending.value
    #expect(await gateway.toolMaintenance == nil)
    let next = try await gateway.startRun(
      GatewayTestValues.request(runID: GatewayTestValues.runID(21)), sessionID: session.sessionID)
    #expect(next.invocationID != nil)
    try await gateway.shutdown()
  }

  @Test
  func terminalReplayDoesNotMakeAStillUnwindingDriverSafeToRefresh() async throws {
    let gate = Gate()
    let gateway = HexGatewayService(driver: TerminalHeldDriver(gate: gate))
    let session = try await gateway.handshake(GatewayTestValues.handshakeRequest())
    _ = try await gateway.startRun(
      GatewayTestValues.request(runID: GatewayTestValues.runID()), sessionID: session.sessionID)
    try await waitUntil { await gate.entered }
    #expect(await gateway.activeRunID == nil)
    #expect(await gateway.liveDriverTasks.count == 1)
    await expectFailure(.toolMaintenanceInProgress) {
      try await gateway.withIdleToolMaintenance {
        _ = Issue.record("Live cleanup must retain ownership.")
      }
    }
    await gate.release()
    try await waitUntil { await gateway.liveDriverTasks.isEmpty }
    let result = try await gateway.withIdleToolMaintenance { "refreshed" }
    #expect(result == "refreshed")
    try await gateway.shutdown()
  }

  @Test
  func cancelledOwnerAndShutdownCannotReleaseNoncooperativeMaintenanceEarly() async throws {
    let gateway = HexGatewayService(driver: ImmediateGatewayRunDriver())
    let session = try await gateway.handshake(GatewayTestValues.handshakeRequest())
    let gate = Gate()
    let pending = Task { try await gateway.withIdleToolMaintenance { await gate.enter() } }
    try await waitUntil { await gate.entered }
    pending.cancel()
    #expect(await gateway.toolMaintenance != nil)
    let began = ContinuousClock.now
    await expectFailure(.transportUnavailable) {
      try await gateway.shutdown(timeout: .milliseconds(20))
    }
    #expect(began.duration(to: ContinuousClock.now) < .seconds(2))
    #expect(await gateway.toolMaintenance != nil)
    #expect(await gateway.drainWaiters.isEmpty)
    #expect(await gateway.shutdownFinalized == false)
    try await gateway.requireSession(session.sessionID)

    let drain = Task { try await gateway.shutdown() }
    try await waitUntil { await gateway.drainWaiters.count == 1 }
    await gate.release()
    do {
      try await pending.value
      Issue.record("Cancelled maintenance owner returned success.")
    } catch is CancellationError {}
    try await drain.value
    #expect(await gateway.toolMaintenance == nil)
    #expect(await gateway.drainWaiters.isEmpty)
    #expect(await gateway.sessions.isEmpty)
    try await gateway.shutdown(timeout: .zero)
  }

  @Test
  func revokedSessionAndAlreadyCancelledCallerNeverDispatchMaintenance() async throws {
    let gateway = HexGatewayService(driver: ImmediateGatewayRunDriver())
    let session = try await gateway.handshake(GatewayTestValues.handshakeRequest())
    await gateway.disconnect(sessionID: session.sessionID)
    await expectFailure(.staleSession) {
      try await gateway.withIdleToolMaintenance(sessionID: session.sessionID) {
        _ = Issue.record("Revoked authority must be checked atomically with idle admission.")
      }
    }
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await gateway.withIdleToolMaintenance {
        _ = Issue.record("Cancelled caller was dispatched.")
      }
    }
    do {
      try await cancelled.value
      Issue.record("Expected cancellation.")
    } catch is CancellationError {}
    #expect(await gateway.toolMaintenance == nil)
  }

  private func expectFailure(_ code: GatewayFailureCode, operation: () async throws -> Void) async {
    do {
      try await operation()
      Issue.record("Expected \(code).")
    } catch let failure as GatewayFailure {
      #expect(failure.code == code)
      if code == .toolMaintenanceInProgress { #expect(failure.isRetryable) }
    } catch { Issue.record("Unexpected failure: \(error)") }
  }

  private func waitUntil(_ predicate: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !(await predicate()) {
      guard ContinuousClock.now < deadline else { throw FixtureError.timedOut }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  private enum FixtureError: Error { case timedOut }

  private actor Gate {
    var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func enter() async {
      entered = true
      await withCheckedContinuation { waiter = $0 }
    }
    func release() {
      waiter?.resume()
      waiter = nil
    }
  }

  private struct TerminalHeldDriver: HexGatewayRunDriver {
    let gate: Gate
    func run(
      _ request: GatewayStartRunRequest,
      emit: @escaping @Sendable (AgentEventRecord) async throws -> Void
    ) async throws {
      try await emit(
        GatewayTestValues.record(runID: request.runID, sequence: 1, event: .runStarted))
      try await emit(
        GatewayTestValues.record(runID: request.runID, sequence: 2, event: .runCompleted))
      await gate.enter()
    }
  }
}
