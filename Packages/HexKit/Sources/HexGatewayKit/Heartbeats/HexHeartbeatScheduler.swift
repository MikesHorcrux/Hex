import Foundation
import HexCore

/// The resident heartbeat coordinator. It owns only scheduling state; the injected runner owns the
/// agent runtime and is called exclusively after a durable occurrence claim. Waiting for a due date,
/// an empty schedule set, or a paused scheduler never reaches the runner.
public actor HexHeartbeatScheduler {
  let store: any HexHeartbeatStore
  let runInspector: (any HexHeartbeatRunInspecting)?
  private let runner: any HexHeartbeatRunner
  let clock: any HexHeartbeatClock
  private let sleeper: any HexHeartbeatSleeper
  private let configuration: HexHeartbeatSchedulerConfiguration

  private var schedules: [HexHeartbeatScheduleID: HexHeartbeatSchedule] = [:]
  private var schedulerPaused = false
  private var hasLoaded = false
  private var initialLoadTask: Task<Void, any Error>?
  private var isStarted = false
  private var executionInProgress = false
  private var mutationInProgress = false
  private var loopTask: Task<Void, Never>?
  private var loopGeneration: UInt64 = 0
  var nextReceiptWakeAt: Date?
  var nextRecoveryCheckAt: Date?

  public init(
    store: any HexHeartbeatStore,
    runner: any HexHeartbeatRunner,
    clock: any HexHeartbeatClock = SystemHexHeartbeatClock(),
    sleeper: any HexHeartbeatSleeper = TaskHexHeartbeatSleeper(),
    configuration: HexHeartbeatSchedulerConfiguration = .standard,
    runInspector: (any HexHeartbeatRunInspecting)? = nil
  ) {
    self.store = store
    self.runner = runner
    self.clock = clock
    self.sleeper = sleeper
    self.configuration = configuration
    self.runInspector = runInspector
  }

  /// Loads durable state, reconciles only expired leases, and starts the cancellable resident loop.
  /// Calling `start` again while started is idempotent.
  public func start() async throws {
    guard !isStarted else {
      return
    }
    _ = try configuration.validated()
    try await ensureLoaded()
    isStarted = true
    launchLoop()
  }

  /// Cancels the resident loop and awaits receipt persistence. Work not yet verified terminal keeps
  /// its durable pending identity for recovery; cancellation never fabricates a finished result.
  public func stop() async {
    isStarted = false
    loopGeneration &+= 1
    let task = loopTask
    loopTask = nil
    task?.cancel()
    if let task {
      await task.value
    }
    if let initialLoadTask {
      _ = try? await initialLoadTask.value
    }
    hasLoaded = false
    schedules.removeAll(keepingCapacity: true)
    schedulerPaused = false
    nextReceiptWakeAt = nil
    nextRecoveryCheckAt = nil
  }

  /// Executes all currently due schedules once, with each schedule's persisted catch-up limit. This
  /// entry point is deterministic and useful for a host wake/reconciliation event; it does not
  /// create a timer or resident task.
  @discardableResult
  public func runDue(at now: Date) async throws -> [HexHeartbeatExecutionReport] {
    try beginExecution()
    defer { endExecution() }
    return try await performDue(at: now)
  }

  public func add(_ schedule: HexHeartbeatSchedule) async throws {
    try await ensureLoaded()
    try beginMutation()
    defer { endMutation() }
    let validated = try schedule.validated()
    let maximumSchedules = configuration.maximumSchedules
    let updated = try await store.mutate { snapshot in
      guard snapshot.schedules.count < maximumSchedules else {
        throw HexHeartbeatSchedulerError.tooManySchedules
      }
      guard snapshot.schedules.first(where: { $0.id == validated.id }) == nil else {
        throw HexHeartbeatSchedulerError.duplicateSchedule(validated.id)
      }
      return Self.replacing(snapshot, with: validated)
    }
    try applyValidated(updated)
    endMutationAndWakeLoop()
  }

  public func remove(_ scheduleID: HexHeartbeatScheduleID) async throws {
    try await ensureLoaded()
    try beginMutation()
    defer { endMutation() }
    let updated = try await store.mutate { snapshot in
      guard snapshot.schedules.contains(where: { $0.id == scheduleID }) else {
        throw HexHeartbeatSchedulerError.scheduleNotFound(scheduleID)
      }
      return HexHeartbeatStoreSnapshot(
        schedules: snapshot.schedules.filter { $0.id != scheduleID },
        isPaused: snapshot.isPaused
      )
    }
    try applyValidated(updated)
    try await refreshReceiptWakeDate()
    endMutationAndWakeLoop()
  }

  public func pause(_ scheduleID: HexHeartbeatScheduleID) async throws {
    try await ensureLoaded()
    try beginMutation()
    defer { endMutation() }
    let updated = try await store.mutate { snapshot in
      guard var schedule = snapshot.schedules.first(where: { $0.id == scheduleID }) else {
        throw HexHeartbeatSchedulerError.scheduleNotFound(scheduleID)
      }
      guard !schedule.isPaused else {
        return snapshot
      }
      schedule.isPaused = true
      return Self.replacing(snapshot, with: schedule)
    }
    try applyValidated(updated)
    endMutationAndWakeLoop()
  }

  public func resume(_ scheduleID: HexHeartbeatScheduleID) async throws {
    try await ensureLoaded()
    try beginMutation()
    defer { endMutation() }
    let updated = try await store.mutate { snapshot in
      guard var schedule = snapshot.schedules.first(where: { $0.id == scheduleID }) else {
        throw HexHeartbeatSchedulerError.scheduleNotFound(scheduleID)
      }
      guard schedule.isPaused else {
        return snapshot
      }
      schedule.isPaused = false
      return Self.replacing(snapshot, with: schedule)
    }
    try applyValidated(updated)
    endMutationAndWakeLoop()
  }

  public func pauseAll() async throws {
    try await ensureLoaded()
    try beginMutation()
    defer { endMutation() }
    let updated = try await store.mutate { snapshot in
      HexHeartbeatStoreSnapshot(schedules: snapshot.schedules, isPaused: true)
    }
    try applyValidated(updated)
    endMutationAndWakeLoop()
  }

  public func resumeAll() async throws {
    try await ensureLoaded()
    try beginMutation()
    defer { endMutation() }
    let updated = try await store.mutate { snapshot in
      HexHeartbeatStoreSnapshot(schedules: snapshot.schedules, isPaused: false)
    }
    try applyValidated(updated)
    endMutationAndWakeLoop()
  }

  public func nextWakeDate() -> Date? {
    let scheduleWake = schedules.values
      .filter { !schedulerPaused && !$0.isPaused }
      .map { schedule in
        // A claimed occurrence cannot be started again before its lease expires. Waking at the
        // due date while that lease is still active would otherwise create a tight retry loop.
        if let expiry = schedule.activeLease?.expiresAt {
          return max(expiry, nextRecoveryCheckAt ?? expiry)
        }
        return schedule.nextDueAt
      }
      .min()
    let receiptWake = nextReceiptWakeAt.map { max($0, nextRecoveryCheckAt ?? $0) }
    return [scheduleWake, receiptWake].compactMap { $0 }.min()
  }

  public func isRunning() -> Bool {
    isStarted
  }

  public func snapshot() async throws -> HexHeartbeatStoreSnapshot {
    try await ensureLoaded()
    return HexHeartbeatStoreSnapshot(
      schedules: schedules.values.sorted { $0.id.description < $1.id.description },
      isPaused: schedulerPaused
    )
  }

  private func performDue(at now: Date) async throws -> [HexHeartbeatExecutionReport] {
    try Self.validate(date: now)
    _ = try configuration.validated()
    guard !mutationInProgress else {
      throw HexHeartbeatSchedulerError.executionInProgress
    }
    try await ensureLoaded()
    guard !mutationInProgress else {
      throw HexHeartbeatSchedulerError.executionInProgress
    }
    let reconciled = try await reconciledSnapshot(at: now)
    try applyValidated(reconciled)
    guard !mutationInProgress else {
      throw HexHeartbeatSchedulerError.executionInProgress
    }
    guard !schedulerPaused else { return [] }
    return try await executeDue(at: now)
  }

  private func executeDue(at now: Date) async throws -> [HexHeartbeatExecutionReport] {
    let dueIDs = schedules.values
      .filter { !$0.isPaused && $0.nextDueAt <= now }
      .map(\.id)
      .sorted { $0.description < $1.description }
    var reports: [HexHeartbeatExecutionReport] = []

    for scheduleID in dueIDs {
      var executedCount = 0
      while executedCount < (schedules[scheduleID]?.maxCatchUpOccurrences ?? 0) {
        try Task.checkCancellation()
        guard !schedulerPaused else {
          break
        }
        guard let schedule = schedules[scheduleID], !schedule.isPaused,
          schedule.nextDueAt <= now
        else {
          break
        }

        let occurrence = schedule.occurrence()
        let lease = makeLease(for: occurrence, at: now)
        let disposition = try await store.claim(lease, at: now)
        switch disposition {
        case .claimed:
          break
        case .alreadyCompleted:
          try await refreshFromStore()
          guard schedules[scheduleID]?.occurrence() != occurrence else {
            throw HexHeartbeatSchedulerError.invalidConfiguration(
              "A completed occurrence is still scheduled. Its saved result was preserved; no work was repeated."
            )
          }
          continue
        case .alreadyClaimed, .scheduleBusy, .schedulePaused, .scheduleNotDue, .scheduleMissing:
          try await refreshFromStore()
          break
        }
        guard case .claimed = disposition else {
          break
        }

        if var claimedSchedule = schedules[scheduleID] {
          claimedSchedule.activeLease = lease
          schedules[scheduleID] = claimedSchedule
        }
        var requestSchedule = schedule
        requestSchedule.activeLease = lease
        let request = HexHeartbeatExecutionRequest(
          schedule: requestSchedule,
          occurrence: occurrence,
          lease: lease
        )
        let execution = await execute(request)
        let nextDueAt = schedule.nextOccurrenceAfter(occurrence.dueAt)
        let completion = try await finishExecution(
          lease: lease,
          outcome: execution.outcome,
          nextDueAt: nextDueAt
        )
        try await refreshFromStore()
        guard let completion else {
          if execution.wasCancelled { throw CancellationError() }
          break
        }
        reports.append(
          HexHeartbeatExecutionReport(
            occurrence: occurrence,
            outcome: completion.outcome
          )
        )
        executedCount += 1
        if execution.wasCancelled {
          throw CancellationError()
        }
      }

      // If a schedule was older than its bounded catch-up window, persist one explicit skipped
      // occurrence and jump directly to the first future boundary. This prevents a long-sleeping
      // Mac from replaying an unbounded backlog over many loop turns.
      guard executedCount > 0,
        let schedule = schedules[scheduleID],
        !schedule.isPaused,
        !schedulerPaused,
        executedCount >= schedule.maxCatchUpOccurrences,
        schedule.nextDueAt <= now
      else {
        continue
      }

      let skippedOccurrence = schedule.occurrence()
      let skippedLease = makeLease(for: skippedOccurrence, at: now)
      let disposition = try await store.claim(skippedLease, at: now)
      guard case .claimed = disposition else {
        try await refreshFromStore()
        continue
      }
      let skippedOutcome = HexHeartbeatOutcome(
        occurrence: skippedOccurrence,
        kind: .skipped,
        completedAt: clock.now,
        failure: nil
      )
      let skippedCompletion = HexHeartbeatCompletion(
        lease: skippedLease,
        outcome: skippedOutcome,
        nextDueAt: schedule.nextDueAfter(skippedOccurrence.dueAt, now: now)
      )
      _ = try await store.complete(skippedCompletion, at: clock.now)
      try await refreshFromStore()
      reports.append(
        HexHeartbeatExecutionReport(
          occurrence: skippedOccurrence,
          outcome: skippedOutcome
        )
      )
    }
    return reports
  }

  private func execute(
    _ request: HexHeartbeatExecutionRequest
  ) async -> HexHeartbeatSchedulerExecution {
    do {
      let result = try await runner.run(request)
      switch result {
      case .succeeded:
        return HexHeartbeatSchedulerExecution(
          outcome: HexHeartbeatOutcome(
            occurrence: request.occurrence,
            kind: .succeeded,
            completedAt: clock.now
          ),
          wasCancelled: false
        )
      case .failed(let failure):
        return HexHeartbeatSchedulerExecution(
          outcome: HexHeartbeatOutcome(
            occurrence: request.occurrence,
            kind: .failed,
            completedAt: clock.now,
            failure: failure
          ),
          wasCancelled: false
        )
      }
    } catch is CancellationError {
      return HexHeartbeatSchedulerExecution(
        outcome: HexHeartbeatOutcome(
          occurrence: request.occurrence,
          kind: .cancelled,
          completedAt: clock.now,
          failure: HexHeartbeatFailure(
            code: .cancelled,
            message: "The heartbeat execution was cancelled.",
            retryable: true
          )
        ),
        wasCancelled: true
      )
    } catch {
      return HexHeartbeatSchedulerExecution(
        outcome: HexHeartbeatOutcome(
          occurrence: request.occurrence,
          kind: .failed,
          completedAt: clock.now,
          failure: HexHeartbeatFailure(
            code: .runnerFailed,
            message: "The heartbeat runner failed.",
            retryable: true
          )
        ),
        wasCancelled: false
      )
    }
  }

  private func ensureLoaded() async throws {
    guard !hasLoaded else {
      return
    }
    if let initialLoadTask {
      try await initialLoadTask.value
      return
    }
    // Snapshot readers and mutations can arrive while inspection is suspended. They share one
    // initial reconciliation so they cannot compute conflicting completions for the same lease.
    let task = Task { [self] in
      let snapshot = try await reconciledSnapshot(at: clock.now)
      try applyValidated(snapshot)
      hasLoaded = true
    }
    initialLoadTask = task
    defer { initialLoadTask = nil }
    try await task.value
  }

  private func refreshFromStore() async throws {
    let snapshot = try await store.load()
    try applyValidated(snapshot)
    try await refreshReceiptWakeDate()
  }

  private func apply(_ snapshot: HexHeartbeatStoreSnapshot) {
    schedules = Dictionary(uniqueKeysWithValues: snapshot.schedules.map { ($0.id, $0) })
    schedulerPaused = snapshot.isPaused
  }

  private func applyValidated(_ snapshot: HexHeartbeatStoreSnapshot) throws {
    guard snapshot.schedules.count <= configuration.maximumSchedules else {
      throw HexHeartbeatSchedulerError.tooManySchedules
    }
    var identifiers = Set<HexHeartbeatScheduleID>()
    for schedule in snapshot.schedules {
      guard identifiers.insert(schedule.id).inserted else {
        throw HexHeartbeatSchedulerError.invalidConfiguration(
          "The heartbeat store contains duplicate schedule identifiers."
        )
      }
      _ = try schedule.validated()
    }
    apply(snapshot)
  }

  private func makeLease(
    for occurrence: HexHeartbeatOccurrenceID,
    at now: Date
  ) -> HexHeartbeatLease {
    HexHeartbeatLease(
      occurrence: occurrence,
      claimedAt: now,
      expiresAt: now.addingTimeInterval(configuration.leaseDurationSeconds),
      runID: AgentRunID()
    )
  }

  private func launchLoop() {
    guard isStarted, loopTask == nil else {
      return
    }
    loopGeneration &+= 1
    let generation = loopGeneration
    loopTask = Task { [weak self] in
      await self?.runLoop(generation: generation)
    }
  }

  private func wakeLoopIfSleeping() {
    guard isStarted, !executionInProgress else {
      return
    }
    loopTask?.cancel()
    loopTask = nil
    launchLoop()
  }

  private func runLoop(generation: UInt64) async {
    defer { finishLoop(generation: generation) }
    while !Task.isCancelled {
      do {
        try beginExecution()
        defer { endExecution() }
        _ = try await performDue(at: clock.now)
      } catch is CancellationError {
        return
      } catch {
        // A durable-store failure stops this loop. The host can surface the error through its next
        // explicit `runDue`/snapshot call or restart the scheduler after repairing the store.
        return
      }
      guard !Task.isCancelled else {
        return
      }
      do {
        try await sleeper.sleep(until: nextWakeDate())
      } catch {
        return
      }
    }
  }

  private func finishLoop(generation: UInt64) {
    guard generation == loopGeneration else {
      return
    }
    loopTask = nil
    isStarted = false
    hasLoaded = false
  }

  private func beginMutation() throws {
    guard !executionInProgress, !mutationInProgress else {
      throw HexHeartbeatSchedulerError.executionInProgress
    }
    mutationInProgress = true
  }

  private func beginExecution() throws {
    guard !executionInProgress, !mutationInProgress else {
      throw HexHeartbeatSchedulerError.executionInProgress
    }
    executionInProgress = true
  }

  private func endExecution() {
    executionInProgress = false
  }

  private func endMutation() {
    mutationInProgress = false
  }

  private func endMutationAndWakeLoop() {
    endMutation()
    wakeLoopIfSleeping()
  }

  private static func replacing(
    _ snapshot: HexHeartbeatStoreSnapshot,
    with schedule: HexHeartbeatSchedule
  ) -> HexHeartbeatStoreSnapshot {
    var schedules = snapshot.schedules
    if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
      schedules[index] = schedule
    } else {
      schedules.append(schedule)
    }
    return HexHeartbeatStoreSnapshot(schedules: schedules, isPaused: snapshot.isPaused)
  }

  private static func validate(date: Date) throws {
    guard date.timeIntervalSinceReferenceDate.isFinite else {
      throw HexHeartbeatSchedulerError.invalidConfiguration(
        "The heartbeat clock returned a non-finite date."
      )
    }
  }

}
