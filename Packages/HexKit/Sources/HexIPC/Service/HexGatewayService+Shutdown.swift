import Foundation

extension HexGatewayService {
  /// Trusted in-process lifecycle control, intentionally not exposed through the gateway wire API.
  /// Existing read/recovery sessions stay valid until successful final shutdown so their owners can
  /// inspect and preserve the durable outcomes of cancelled work.
  public func beginShutdown() {
    admissionsClosed = true
    taskWake?.cancel()
    taskWake = nil
    taskPump?.cancel()
    for runID in Array(runs.keys) {
      guard var state = runs[runID], state.phase != .terminal else { continue }
      state.phase = .cancelling
      runs[runID] = state
    }
    for task in liveDriverTasks.values { task.cancel() }
    toolMaintenance?.cancel()
  }

  /// Cancels admission and awaits actual driver completion, including drivers whose terminal replay
  /// was evicted. Caller cancellation never abandons cleanup. Deadline expiry leaves all ownership
  /// and sessions intact; the owner must keep shared storage/resources open and retry this drain.
  public func drainRuns(timeout: Duration = .seconds(10)) async throws {
    beginShutdown()
    guard !liveDriverTasks.isEmpty || toolMaintenance != nil || taskPump != nil else { return }
    guard timeout > .zero else { throw drainTimeoutFailure() }

    let waiterID = UUID()
    try await withCheckedThrowingContinuation { continuation in
      // An unstructured timer is deliberate: a task-group race would wait on a noncooperative
      // child during group teardown, defeating the deadline. Do not inherit caller cancellation.
      let timer = Task.detached { [weak self] in
        do { try await Task.sleep(for: timeout) } catch { return }
        await self?.expireDrainWaiter(waiterID)
      }
      drainWaiters[waiterID] = GatewayDriverDrainWaiter(
        continuation: continuation, timer: timer)
    }
  }

  /// Finalizes only after all drivers returned. Safe to call concurrently, after timeout, or from an
  /// already-cancelled teardown task. This method neither closes injected storage nor invents run
  /// events; the trusted composition owner closes shared resources after this receipt succeeds.
  public func shutdown(timeout: Duration = .seconds(10)) async throws {
    try await drainRuns(timeout: timeout)
    guard !shutdownFinalized else { return }
    shutdownFinalized = true
    let failure = GatewayFailure(
      code: .transportUnavailable,
      message: "The gateway has shut down.",
      isRetryable: true)
    sessions.removeAll()
    for runID in Array(runs.keys) {
      guard var state = runs[runID] else { continue }
      for subscriber in state.subscribers.values {
        subscriber.continuation.finish(throwing: failure)
      }
      state.subscribers.removeAll()
      runs[runID] = state
    }
  }

  func requireAcceptingAdmissions() throws {
    guard !admissionsClosed else {
      throw GatewayFailure(
        code: .transportUnavailable,
        message: "The gateway is shutting down. No new session or run was started.",
        isRetryable: true)
    }
  }

  func driverTaskExited(_ invocationID: GatewayRunInvocationID) {
    guard liveDriverTasks.removeValue(forKey: invocationID) != nil else { return }
    resumeDrainWaitersIfIdle()
    wakeTaskScheduler()
  }

  func resumeDrainWaitersIfIdle() {
    guard liveDriverTasks.isEmpty, toolMaintenance == nil, taskPump == nil else { return }
    let completed = drainWaiters
    drainWaiters.removeAll()
    for waiter in completed.values {
      waiter.timer.cancel()
      waiter.continuation.resume()
    }
  }

  private func expireDrainWaiter(_ waiterID: UUID) {
    guard let waiter = drainWaiters.removeValue(forKey: waiterID) else { return }
    waiter.timer.cancel()
    waiter.continuation.resume(throwing: drainTimeoutFailure())
  }

  private func drainTimeoutFailure() -> GatewayFailure {
    GatewayFailure(
      code: .transportUnavailable,
      message:
        "Run cleanup is still in progress. Keep gateway resources open and retry shutdown; no unfinished work was declared safe or completed.",
      isRetryable: true)
  }
}
