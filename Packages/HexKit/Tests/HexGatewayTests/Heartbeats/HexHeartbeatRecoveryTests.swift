import Foundation
import HexCore
import HexIPC
import HexPersistence
import Testing

@testable import HexGatewayKit

@Suite("Scheduled receipt recovery without duplicate execution")
struct HexHeartbeatRecoveryTests {
  @Test
  func journalCompletionSurvivesCrashBeforeSchedulerCompletion() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("schedules.sqlite")
    let provider = GatewayTestInferenceProvider()
    let configuration = HexGatewayCompositionConfiguration(
      journalConfiguration: SQLiteAgentEventJournalConfiguration(
        databaseURL: directory.appendingPathComponent("journal.sqlite")),
      inferenceProvider: provider, toolExecutor: GatewayTestToolExecutor(),
      authorizationProvider: GatewayTestAuthorizationProvider())
    let composition = try await HexGatewayComposition.open(configuration: configuration)
    let store = try await SQLiteHexHeartbeatStore.open(databaseURL: storeURL)
    let client = HexGatewayClient(transport: composition.transport)
    let now = Date()
    let schedule = try HexHeartbeatSchedule(
      name: "Recovered completion", instruction: "Reply once.", intervalSeconds: 60, nextDueAt: now)
    let lease = HexHeartbeatLease(
      occurrence: schedule.occurrence(), claimedAt: now,
      expiresAt: now.addingTimeInterval(30), runID: AgentRunID())
    do {
      try await store.replace(HexHeartbeatStoreSnapshot(schedules: [schedule]))
      #expect(try await store.claim(lease, at: now) == .claimed)
      _ = try await client.connect()
      let runner = try HexGatewayHeartbeatRunner(
        client: client,
        authorizationPolicy: HexHeartbeatAuthorizationPolicy(
          interactivePrompter: HexGatewayAuthorizationBroker()),
        modelID: provider.modelID, workspaceRoot: directory)
      _ = try await runner.run(
        HexHeartbeatExecutionRequest(schedule: schedule, occurrence: lease.occurrence, lease: lease)
      )
      // Simulate process loss at the exact boundary: native terminal is committed, occurrence
      // receipt is still pending. Never call store.complete for this original worker.
      #expect(try await store.receipts().receipts.first?.outcome == nil)
      try await client.disconnect()
      try await composition.close()
      try await store.close()
    } catch {
      try? await client.disconnect()
      try? await composition.close()
      try? await store.close()
      throw error
    }
    let reopened = try await SQLiteHexHeartbeatStore.open(databaseURL: storeURL)
    let newComposition = try await HexGatewayComposition.open(configuration: configuration)
    let readClient = HexGatewayClient(transport: newComposition.transport)
    do {
      _ = try await readClient.connect()
      let replacementRunner = RecordingRunner()
      let afterExpiry = now.addingTimeInterval(90)
      let scheduler = HexHeartbeatScheduler(
        store: reopened, runner: replacementRunner, clock: FixedClock(now: afterExpiry),
        runInspector: HexGatewayHeartbeatRunInspector(client: readClient))
      #expect(try await scheduler.runDue(at: afterExpiry).isEmpty)
      #expect(await replacementRunner.count == 0)
      let saved = try #require(try await scheduler.receipts().receipts.first)
      #expect(saved.outcome?.kind == .succeeded)
      #expect(saved.runID == lease.runID)
      #expect(saved.journal?.runID == lease.runID)
      #expect(try await scheduler.snapshot().schedules.first?.activeLease == nil)
      #expect(
        try await scheduler.snapshot().schedules.first?.nextDueAt ?? .distantPast > afterExpiry)
      try await readClient.disconnect()
      try await newComposition.close()
      try await reopened.close()
    } catch {
      try? await readClient.disconnect()
      try? await newComposition.close()
      try? await reopened.close()
      throw error
    }
  }

  @Test(arguments: [InspectionMode.running, .unknown, .unavailable])
  func expiredLeaseIsNotPermissionToRunTheSameOccurrenceAgain(_ mode: InspectionMode) async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await SQLiteHexHeartbeatStore.open(
      databaseURL: directory.appendingPathComponent("schedules.sqlite"))
    let claimedAt = Date(timeIntervalSinceReferenceDate: 1_000)
    let now = claimedAt.addingTimeInterval(11)
    let schedule = try HexHeartbeatSchedule(
      name: "Uncertain work", instruction: "An action may already have happened.",
      intervalSeconds: 60, nextDueAt: claimedAt)
    let lease = HexHeartbeatLease(
      occurrence: schedule.occurrence(), claimedAt: claimedAt,
      expiresAt: claimedAt.addingTimeInterval(10), runID: AgentRunID())
    do {
      try await store.replace(HexHeartbeatStoreSnapshot(schedules: [schedule]))
      #expect(try await store.claim(lease, at: claimedAt) == .claimed)
      let runner = RecordingRunner()
      let scheduler = HexHeartbeatScheduler(
        store: store, runner: runner, clock: FixedClock(now: now),
        runInspector: Inspector(mode: mode))
      if mode == .unavailable {
        await #expect(throws: InspectionError.self) { try await scheduler.runDue(at: now) }
      } else {
        #expect(try await scheduler.runDue(at: now).isEmpty)
      }
      #expect(await runner.count == 0)
      let receipt = try #require(try await store.receipts().receipts.first)
      if mode == .unknown {
        #expect(receipt.outcome?.kind == .interrupted)
        #expect(receipt.outcome?.failure?.message.contains("Actions may have occurred") == true)
      } else {
        #expect(receipt.outcome == nil)
        #expect(receipt.lease == lease)
      }
      if mode == .running {
        #expect(await scheduler.nextWakeDate() == now.addingTimeInterval(5))
        try await scheduler.remove(schedule.id)
        #expect(try await store.load().schedules.isEmpty)
        #expect(try await store.nextPendingReceiptExpiry() == lease.expiresAt)
        #expect(await scheduler.nextWakeDate() == now.addingTimeInterval(5))
      }
      try await store.close()
    } catch {
      try? await store.close()
      throw error
    }
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("hex-heartbeat-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    return directory
  }

  @Test
  func timedOutObserverDoesNotHideLaterSuccessfulWork() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await SQLiteHexHeartbeatStore.open(
      databaseURL: directory.appendingPathComponent("schedules.sqlite"))
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let schedule = try HexHeartbeatSchedule(
      name: "Slow work", instruction: "Complete once.", intervalSeconds: 60, nextDueAt: now)
    let inspector = CompletingInspector(completedAt: now)
    let runner = RecordingRunner(
      result: .failed(
        HexHeartbeatFailure(
          code: .timedOut, message: "The observer timed out.", retryable: true)))
    let scheduler = HexHeartbeatScheduler(
      store: store, runner: runner, clock: FixedClock(now: now),
      configuration: HexHeartbeatSchedulerConfiguration(leaseDurationSeconds: 30),
      runInspector: inspector)
    do {
      try await scheduler.add(schedule)
      #expect(try await scheduler.runDue(at: now).isEmpty)
      let pending = try #require(try await store.receipts().receipts.first)
      #expect(pending.outcome == nil)
      #expect(try await scheduler.snapshot().schedules.first?.activeLease == pending.lease)
      #expect(await scheduler.nextWakeDate() == now.addingTimeInterval(30))
      await inspector.complete()
      #expect(try await scheduler.runDue(at: now.addingTimeInterval(31)).isEmpty)
      let completed = try #require(try await store.receipts().receipts.first)
      #expect(completed.lease == pending.lease)
      #expect(completed.outcome?.kind == .succeeded)
      #expect(completed.journal?.runID == pending.runID)
      #expect(await runner.count == 1)
      try await store.close()
    } catch {
      try? await store.close()
      throw error
    }
  }

  @Test
  func concurrentInitialReadersShareOneReconciliation() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await SQLiteHexHeartbeatStore.open(
      databaseURL: directory.appendingPathComponent("schedules.sqlite"))
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let schedule = try HexHeartbeatSchedule(
      name: "Recover once", instruction: "Do not repeat.", intervalSeconds: 60, nextDueAt: now)
    let lease = HexHeartbeatLease(
      occurrence: schedule.occurrence(), claimedAt: now,
      expiresAt: now.addingTimeInterval(10), runID: AgentRunID())
    do {
      try await store.replace(HexHeartbeatStoreSnapshot(schedules: [schedule]))
      #expect(try await store.claim(lease, at: now) == .claimed)
      let inspector = CountingUnknownInspector()
      let scheduler = HexHeartbeatScheduler(
        store: store, runner: RecordingRunner(), clock: FixedClock(now: now.addingTimeInterval(11)),
        runInspector: inspector)
      try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<20 {
          group.addTask { _ = try await scheduler.snapshot() }
        }
        try await group.waitForAll()
      }
      #expect(await inspector.count == 1)
      #expect(try await store.receipts().receipts.first?.outcome?.kind == .interrupted)
      try await store.close()
    } catch {
      try? await store.close()
      throw error
    }
  }

  enum InspectionMode: Sendable { case running, unknown, unavailable }
  private enum InspectionError: Error { case unavailable }
  private struct FixedClock: HexHeartbeatClock { let now: Date }
  private struct Inspector: HexHeartbeatRunInspecting {
    let mode: InspectionMode
    func inspect(_ lease: HexHeartbeatLease) throws -> HexHeartbeatRunInspection {
      switch mode {
      case .running: .running
      case .unknown: .unknown
      case .unavailable: throw InspectionError.unavailable
      }
    }
  }
  private actor RecordingRunner: HexHeartbeatRunner {
    private(set) var count = 0
    let result: HexHeartbeatExecutionResult
    init(result: HexHeartbeatExecutionResult = .succeeded) { self.result = result }
    func run(_ request: HexHeartbeatExecutionRequest) -> HexHeartbeatExecutionResult {
      count += 1
      return result
    }
  }
  private actor CompletingInspector: HexHeartbeatRunInspecting {
    let completedAt: Date
    private var isComplete = false
    init(completedAt: Date) { self.completedAt = completedAt }
    func complete() { isComplete = true }
    func inspect(_ lease: HexHeartbeatLease) throws -> HexHeartbeatRunInspection {
      guard isComplete else { return .running }
      let runID = try #require(lease.runID)
      return .terminal(
        outcome: HexHeartbeatOutcome(
          occurrence: lease.occurrence, kind: .succeeded, completedAt: completedAt),
        journal: HexHeartbeatRunJournalIdentity(
          runID: runID, firstEventID: AgentEventID(), terminalSequence: 2))
    }
  }
  private actor CountingUnknownInspector: HexHeartbeatRunInspecting {
    private(set) var count = 0
    func inspect(_ lease: HexHeartbeatLease) async -> HexHeartbeatRunInspection {
      count += 1
      await Task.yield()
      return .unknown
    }
  }
}
