import Foundation
import HexGatewayKit
import Testing

@Suite("Heartbeat scheduler")
struct HexHeartbeatSchedulerTests {
  @Test
  func executesDueOccurrenceAndPersistsOutcome() async throws {
    let fileURL = Self.temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let dueAt = Self.date(1_000)
    let schedule = try Self.schedule(dueAt: dueAt)
    let store = JSONHexHeartbeatStore(fileURL: fileURL)
    let runner = RecordingRunner()
    let scheduler = Self.scheduler(
      store: store,
      runner: runner,
      now: dueAt.addingTimeInterval(1)
    )
    try await scheduler.add(schedule)

    let reports = try await scheduler.runDue(at: dueAt.addingTimeInterval(1))
    let snapshot = try await scheduler.snapshot()

    #expect(reports.count == 1)
    #expect(reports.first?.outcome.kind == .succeeded)
    #expect(await runner.callCount() == 1)
    #expect(snapshot.schedules.first?.lastOutcome?.kind == .succeeded)
    #expect(snapshot.schedules.first?.nextDueAt == dueAt.addingTimeInterval(60))
  }

  @Test
  func futureScheduleDoesNotInvokeRunnerWhileIdle() async throws {
    let fileURL = Self.temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let dueAt = Self.date(2_000)
    let schedule = try Self.schedule(dueAt: dueAt)
    let store = JSONHexHeartbeatStore(fileURL: fileURL)
    let runner = RecordingRunner()
    let scheduler = Self.scheduler(store: store, runner: runner, now: Self.date(1_000))
    try await scheduler.add(schedule)

    let reports = try await scheduler.runDue(at: Self.date(1_000))

    #expect(reports.isEmpty)
    #expect(await runner.callCount() == 0)
    #expect(await scheduler.nextWakeDate() == dueAt)
  }

  @Test
  func pausedScheduleDoesNotInvokeRunner() async throws {
    let fileURL = Self.temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let dueAt = Self.date(1_000)
    let schedule = try Self.schedule(dueAt: dueAt)
    let store = JSONHexHeartbeatStore(fileURL: fileURL)
    let runner = RecordingRunner()
    let scheduler = Self.scheduler(store: store, runner: runner, now: dueAt)
    try await scheduler.add(schedule)
    try await scheduler.pause(schedule.id)

    let reports = try await scheduler.runDue(at: dueAt)
    let snapshot = try await scheduler.snapshot()

    #expect(reports.isEmpty)
    #expect(await runner.callCount() == 0)
    #expect(snapshot.schedules.first?.isPaused == true)
    #expect(snapshot.schedules.first?.nextDueAt == dueAt)
  }

  @Test
  func restartDoesNotDoubleStartAnUnexpiredClaim() async throws {
    let fileURL = Self.temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let dueAt = Self.date(1_000)
    let schedule = try Self.schedule(dueAt: dueAt)
    let store = JSONHexHeartbeatStore(fileURL: fileURL)
    try await store.replace(HexHeartbeatStoreSnapshot(schedules: [schedule]))
    let occurrence = schedule.occurrence()
    let lease = HexHeartbeatLease(
      occurrence: occurrence,
      claimedAt: dueAt,
      expiresAt: dueAt.addingTimeInterval(600)
    )
    #expect(await store.claim(lease, at: dueAt) == .claimed)

    let runner = RecordingRunner()
    let scheduler = Self.scheduler(
      store: JSONHexHeartbeatStore(fileURL: fileURL),
      runner: runner,
      now: dueAt.addingTimeInterval(1),
      leaseDurationSeconds: 60
    )
    let reports = try await scheduler.runDue(at: dueAt.addingTimeInterval(1))

    #expect(reports.isEmpty)
    #expect(await runner.callCount() == 0)
    let snapshot = try await scheduler.snapshot()
    #expect(snapshot.schedules.first?.activeLease == lease)
  }

  @Test
  func expiredLeaseIsInterruptedAndNotReplayedAfterWake() async throws {
    let fileURL = Self.temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let dueAt = Self.date(1_000)
    let schedule = try Self.schedule(dueAt: dueAt, intervalSeconds: 10, maxCatchUp: 2)
    let store = JSONHexHeartbeatStore(fileURL: fileURL)
    try await store.replace(HexHeartbeatStoreSnapshot(schedules: [schedule]))
    let lease = HexHeartbeatLease(
      occurrence: schedule.occurrence(),
      claimedAt: dueAt,
      expiresAt: dueAt.addingTimeInterval(5)
    )
    #expect(await store.claim(lease, at: dueAt) == .claimed)

    let runner = RecordingRunner()
    let scheduler = Self.scheduler(
      store: JSONHexHeartbeatStore(fileURL: fileURL),
      runner: runner,
      now: Self.date(2_000),
      leaseDurationSeconds: 60
    )
    let reports = try await scheduler.runDue(at: Self.date(2_000))
    let snapshot = try await scheduler.snapshot()

    #expect(reports.isEmpty)
    #expect(await runner.callCount() == 0)
    #expect(snapshot.schedules.first?.lastOutcome?.kind == .interrupted)
    #expect(snapshot.schedules.first?.nextDueAt ?? .distantPast > Self.date(2_000))
  }

  @Test
  func catchUpIsBoundedAndSkipsRemainingBacklog() async throws {
    let fileURL = Self.temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let dueAt = Self.date(1_000)
    let schedule = try Self.schedule(dueAt: dueAt, intervalSeconds: 10, maxCatchUp: 2)
    let store = JSONHexHeartbeatStore(fileURL: fileURL)
    let runner = RecordingRunner()
    let scheduler = Self.scheduler(store: store, runner: runner, now: Self.date(2_000))
    try await scheduler.add(schedule)

    let reports = try await scheduler.runDue(at: Self.date(2_000))
    let snapshot = try await scheduler.snapshot()

    #expect(await runner.callCount() == 2)
    #expect(reports.count == 3)
    #expect(reports.last?.outcome.kind == .skipped)
    #expect(snapshot.schedules.first?.nextDueAt ?? .distantPast > Self.date(2_000))
  }

  @Test
  func duplicateLeaseIsRejectedAndStaleCompletionCannotCommit() async throws {
    let fileURL = Self.temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let dueAt = Self.date(1_000)
    let schedule = try Self.schedule(dueAt: dueAt)
    let store = JSONHexHeartbeatStore(fileURL: fileURL)
    try await store.replace(HexHeartbeatStoreSnapshot(schedules: [schedule]))
    let occurrence = schedule.occurrence()
    let lease = HexHeartbeatLease(
      occurrence: occurrence,
      claimedAt: dueAt,
      expiresAt: dueAt.addingTimeInterval(600)
    )
    let duplicate = HexHeartbeatLease(
      occurrence: occurrence,
      claimedAt: dueAt,
      expiresAt: dueAt.addingTimeInterval(600)
    )

    #expect(await store.claim(lease, at: dueAt) == .claimed)
    #expect(await store.claim(duplicate, at: dueAt) == .alreadyClaimed)
    let outcome = HexHeartbeatOutcome(
      occurrence: occurrence,
      kind: .succeeded,
      completedAt: dueAt
    )
    do {
      _ = try await store.complete(
        HexHeartbeatCompletion(
          lease: duplicate,
          outcome: outcome,
          nextDueAt: dueAt.addingTimeInterval(60)
        )
      )
      Issue.record("Expected a stale duplicate lease completion to be rejected.")
    } catch let error as HexHeartbeatStoreError {
      #expect(error == .staleLease)
    }
  }

  @Test
  func cancellationCommitsCancelledOutcome() async throws {
    let fileURL = Self.temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let dueAt = Self.date(1_000)
    let schedule = try Self.schedule(dueAt: dueAt)
    let store = JSONHexHeartbeatStore(fileURL: fileURL)
    let runner = CancellationRunner()
    let scheduler = Self.scheduler(store: store, runner: runner, now: dueAt)
    try await scheduler.add(schedule)
    let task = Task {
      try await scheduler.runDue(at: dueAt)
    }
    while await runner.callCount() == 0 {
      await Task.yield()
    }
    task.cancel()

    do {
      _ = try await task.value
      Issue.record("Expected the cancelled heartbeat run to throw CancellationError.")
    } catch is CancellationError {
      // Expected: the cancellation is also durably recorded below.
    }
    let snapshot = try await scheduler.snapshot()
    #expect(snapshot.schedules.first?.lastOutcome?.kind == .cancelled)
    #expect(await runner.callCount() == 1)
  }

  private static func scheduler(
    store: any HexHeartbeatStore,
    runner: any HexHeartbeatRunner,
    now: Date,
    leaseDurationSeconds: TimeInterval = 600
  ) -> HexHeartbeatScheduler {
    HexHeartbeatScheduler(
      store: store,
      runner: runner,
      clock: FixedClock(now: now),
      sleeper: NoopSleeper(),
      configuration: HexHeartbeatSchedulerConfiguration(
        leaseDurationSeconds: leaseDurationSeconds,
        maximumSchedules: 16
      )
    )
  }

  private static func schedule(
    dueAt: Date,
    intervalSeconds: TimeInterval = 60,
    maxCatchUp: Int = 1
  ) throws -> HexHeartbeatSchedule {
    try HexHeartbeatSchedule(
      name: "test heartbeat",
      instruction: "run the test heartbeat",
      intervalSeconds: intervalSeconds,
      nextDueAt: dueAt,
      maxCatchUpOccurrences: maxCatchUp
    )
  }

  private static func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: seconds)
  }

  private static func temporaryStoreURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hex-heartbeat-" + UUID().uuidString)
      .appendingPathComponent("state.json")
  }

  private struct FixedClock: HexHeartbeatClock, Sendable {
    let now: Date
  }

  private struct NoopSleeper: HexHeartbeatSleeper, Sendable {
    func sleep(until date: Date?) async throws {
      _ = date
      try await Task.sleep(for: .hours(24))
    }
  }

  private actor RecordingRunner: HexHeartbeatRunner {
    private var calls = 0

    func run(_ request: HexHeartbeatExecutionRequest) async throws -> HexHeartbeatExecutionResult {
      _ = request
      calls += 1
      return .succeeded
    }

    func callCount() -> Int {
      calls
    }
  }

  private actor CancellationRunner: HexHeartbeatRunner {
    private var calls = 0

    func run(_ request: HexHeartbeatExecutionRequest) async throws -> HexHeartbeatExecutionResult {
      _ = request
      calls += 1
      try await Task.sleep(for: .hours(24))
      return .succeeded
    }

    func callCount() -> Int {
      calls
    }
  }
}
