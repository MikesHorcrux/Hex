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
    let initialClaim = try await store.claim(lease, at: dueAt)
    #expect(initialClaim == .claimed)

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
    let initialClaim = try await store.claim(lease, at: dueAt)
    #expect(initialClaim == .claimed)

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

    let initialClaim = try await store.claim(lease, at: dueAt)
    #expect(initialClaim == .claimed)
    let duplicateClaim = try await store.claim(duplicate, at: dueAt)
    #expect(duplicateClaim == .alreadyClaimed)
    let outcome = HexHeartbeatOutcome(
      occurrence: occurrence,
      kind: .succeeded,
      completedAt: dueAt
    )
    let initialCompletion = try await store.complete(
      HexHeartbeatCompletion(
        lease: lease,
        outcome: outcome,
        nextDueAt: dueAt.addingTimeInterval(60)
      ),
      at: dueAt
    )
    #expect(initialCompletion == .completed)
    let repeatedCompletion = try await store.complete(
      HexHeartbeatCompletion(
        lease: lease,
        outcome: outcome,
        nextDueAt: dueAt.addingTimeInterval(60)
      ),
      at: dueAt.addingTimeInterval(1)
    )
    #expect(repeatedCompletion == .alreadyCompleted)
    do {
      _ = try await store.complete(
        HexHeartbeatCompletion(
          lease: duplicate,
          outcome: outcome,
          nextDueAt: dueAt.addingTimeInterval(60)
        ),
        at: dueAt.addingTimeInterval(1)
      )
      Issue.record("Expected a stale duplicate lease completion to be rejected.")
    } catch let error as HexHeartbeatStoreError {
      #expect(error == .staleLease)
    }
    let completedSnapshot = try await store.load()
    #expect(completedSnapshot.schedules.first?.lastCompletedLeaseID == lease.leaseID)
  }

  @Test
  func concurrentStoresAtomicallyClaimOneOccurrence() async throws {
    let fileURL = Self.temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let dueAt = Self.date(1_000)
    let schedule = try Self.schedule(dueAt: dueAt)
    let firstStore = JSONHexHeartbeatStore(fileURL: fileURL)
    let secondStore = JSONHexHeartbeatStore(fileURL: fileURL)
    try await firstStore.replace(HexHeartbeatStoreSnapshot(schedules: [schedule]))
    let occurrence = schedule.occurrence()
    let firstLease = HexHeartbeatLease(
      leaseID: UUID(),
      occurrence: occurrence,
      claimedAt: dueAt,
      expiresAt: dueAt.addingTimeInterval(600)
    )
    let secondLease = HexHeartbeatLease(
      leaseID: UUID(),
      occurrence: occurrence,
      claimedAt: dueAt,
      expiresAt: dueAt.addingTimeInterval(600)
    )

    async let firstDisposition = firstStore.claim(firstLease, at: dueAt)
    async let secondDisposition = secondStore.claim(secondLease, at: dueAt)
    let first = try await firstDisposition
    let second = try await secondDisposition

    #expect((first == .claimed) != (second == .claimed))
    #expect(first == .alreadyClaimed || second == .alreadyClaimed)
  }

  @Test
  func concurrentSchedulersAtomicallyPreserveDifferentMutations() async throws {
    let fileURL = Self.temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let dueAt = Self.date(1_000)
    let firstSchedule = try Self.schedule(dueAt: dueAt)
    let secondSchedule = try Self.schedule(dueAt: dueAt)
    let firstScheduler = Self.scheduler(
      store: JSONHexHeartbeatStore(fileURL: fileURL),
      runner: RecordingRunner(),
      now: dueAt
    )
    let secondScheduler = Self.scheduler(
      store: JSONHexHeartbeatStore(fileURL: fileURL),
      runner: RecordingRunner(),
      now: dueAt
    )

    async let firstAdd = firstScheduler.add(firstSchedule)
    async let secondAdd = secondScheduler.add(secondSchedule)
    try await firstAdd
    try await secondAdd

    let snapshot = try await JSONHexHeartbeatStore(fileURL: fileURL).load()
    #expect(Set(snapshot.schedules.map(\.id)) == Set([firstSchedule.id, secondSchedule.id]))
  }

  @Test
  func completionRejectsAnExpiredLeaseUsingAuthoritativeTime() async throws {
    let fileURL = Self.temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let dueAt = Self.date(1_000)
    let schedule = try Self.schedule(dueAt: dueAt)
    let store = JSONHexHeartbeatStore(fileURL: fileURL)
    try await store.replace(HexHeartbeatStoreSnapshot(schedules: [schedule]))
    let lease = HexHeartbeatLease(
      occurrence: schedule.occurrence(),
      claimedAt: dueAt,
      expiresAt: dueAt.addingTimeInterval(5)
    )
    let firstClaim = try await store.claim(lease, at: dueAt)
    #expect(firstClaim == .claimed)
    let completion = HexHeartbeatCompletion(
      lease: lease,
      outcome: HexHeartbeatOutcome(
        occurrence: lease.occurrence,
        kind: .succeeded,
        completedAt: dueAt.addingTimeInterval(1)
      ),
      nextDueAt: dueAt.addingTimeInterval(60)
    )

    do {
      _ = try await store.complete(completion, at: dueAt.addingTimeInterval(5))
      Issue.record("Expected completion after lease expiry to be rejected.")
    } catch let error as HexHeartbeatStoreError {
      #expect(error == .staleLease)
    }
    let expiredSnapshot = try await store.load()
    #expect(expiredSnapshot.schedules.first?.activeLease == lease)
  }

  @Test
  func mutationsAreRejectedWhileExecutionIsInProgress() async throws {
    let fileURL = Self.temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let dueAt = Self.date(1_000)
    let schedule = try Self.schedule(dueAt: dueAt)
    let futureSchedule = try Self.schedule(dueAt: dueAt.addingTimeInterval(600))
    let store = JSONHexHeartbeatStore(fileURL: fileURL)
    let runner = BlockingRunner()
    let scheduler = Self.scheduler(store: store, runner: runner, now: dueAt)
    try await scheduler.add(schedule)
    let runTask = Task { try await scheduler.runDue(at: dueAt) }
    while await runner.callCount() == 0 {
      await Task.yield()
    }

    do {
      try await scheduler.add(futureSchedule)
      Issue.record("Expected add to be rejected during execution.")
    } catch let error as HexHeartbeatSchedulerError {
      #expect(error == .executionInProgress)
    }
    do {
      try await scheduler.remove(schedule.id)
      Issue.record("Expected remove to be rejected during execution.")
    } catch let error as HexHeartbeatSchedulerError {
      #expect(error == .executionInProgress)
    }
    do {
      try await scheduler.pause(schedule.id)
      Issue.record("Expected pause to be rejected during execution.")
    } catch let error as HexHeartbeatSchedulerError {
      #expect(error == .executionInProgress)
    }
    do {
      try await scheduler.resume(schedule.id)
      Issue.record("Expected resume to be rejected during execution.")
    } catch let error as HexHeartbeatSchedulerError {
      #expect(error == .executionInProgress)
    }

    await runner.release()
    _ = try await runTask.value
  }

  @Test
  func concurrentRunDueCallsAreRejectedBeforeASecondRunnerStarts() async throws {
    let fileURL = Self.temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let dueAt = Self.date(1_000)
    let schedule = try Self.schedule(dueAt: dueAt)
    let runner = BlockingRunner()
    let scheduler = Self.scheduler(
      store: JSONHexHeartbeatStore(fileURL: fileURL),
      runner: runner,
      now: dueAt
    )
    try await scheduler.add(schedule)
    let firstRun = Task { try await scheduler.runDue(at: dueAt) }
    while await runner.callCount() == 0 {
      await Task.yield()
    }

    let secondRun = Task { () -> Bool in
      do {
        _ = try await scheduler.runDue(at: dueAt)
        return false
      } catch let error as HexHeartbeatSchedulerError {
        return error == .executionInProgress
      } catch {
        return false
      }
    }

    #expect(await secondRun.value)
    await runner.release()
    _ = try await firstRun.value
  }

  @Test
  func nextWakeUsesActiveLeaseExpiryInsteadOfDueDate() async throws {
    let fileURL = Self.temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let dueAt = Self.date(1_000)
    let schedule = try Self.schedule(dueAt: dueAt)
    let store = JSONHexHeartbeatStore(fileURL: fileURL)
    try await store.replace(HexHeartbeatStoreSnapshot(schedules: [schedule]))
    let lease = HexHeartbeatLease(
      occurrence: schedule.occurrence(),
      claimedAt: dueAt,
      expiresAt: dueAt.addingTimeInterval(600)
    )
    let firstClaim = try await store.claim(lease, at: dueAt)
    #expect(firstClaim == .claimed)
    let scheduler = Self.scheduler(
      store: JSONHexHeartbeatStore(fileURL: fileURL),
      runner: RecordingRunner(),
      now: dueAt.addingTimeInterval(1)
    )
    _ = try await scheduler.snapshot()

    #expect(await scheduler.nextWakeDate() == lease.expiresAt)
  }

  @Test
  func failedResidentLoopResetsStateForRestart() async throws {
    let fileURL = Self.temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let dueAt = Self.date(1_000)
    let schedule = try Self.schedule(dueAt: dueAt.addingTimeInterval(600))
    let sleeper = FailOnceSleeper()
    let scheduler = HexHeartbeatScheduler(
      store: JSONHexHeartbeatStore(fileURL: fileURL),
      runner: RecordingRunner(),
      clock: FixedClock(now: dueAt),
      sleeper: sleeper,
      configuration: HexHeartbeatSchedulerConfiguration(
        leaseDurationSeconds: 600,
        maximumSchedules: 16
      )
    )
    try await scheduler.add(schedule)
    try await scheduler.start()

    for _ in 0..<200 {
      if await sleeper.callCount() >= 1 {
        break
      }
      await Task.yield()
    }
    for _ in 0..<200 {
      try await scheduler.start()
      if await sleeper.callCount() >= 2 {
        break
      }
      await Task.yield()
    }

    #expect(await sleeper.callCount() >= 2)
    await scheduler.stop()
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
      try await Task.sleep(nanoseconds: 86_400_000_000_000)
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
      try await Task.sleep(nanoseconds: 86_400_000_000_000)
      return .succeeded
    }

    func callCount() -> Int {
      calls
    }
  }

  private actor BlockingRunner: HexHeartbeatRunner {
    private var calls = 0
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func run(_ request: HexHeartbeatExecutionRequest) async throws -> HexHeartbeatExecutionResult {
      _ = request
      calls += 1
      await withCheckedContinuation { continuation in
        releaseContinuation = continuation
      }
      return .succeeded
    }

    func callCount() -> Int {
      calls
    }

    func release() {
      releaseContinuation?.resume()
      releaseContinuation = nil
    }
  }

  private actor FailOnceSleeper: HexHeartbeatSleeper {
    private var calls = 0

    func sleep(until date: Date?) async throws {
      _ = date
      calls += 1
      if calls == 1 {
        throw SleeperFailure()
      }
      try await Task.sleep(nanoseconds: 86_400_000_000_000)
    }

    func callCount() -> Int {
      calls
    }
  }

  private struct SleeperFailure: Error, Sendable {}
}
