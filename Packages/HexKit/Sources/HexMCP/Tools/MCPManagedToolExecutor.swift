import Foundation
import HexCore
import Synchronization

/// Keeps one MCP server optional at the runtime boundary.
///
/// Cold discovery may wait or return the current catalog while an owned startup runs. Once unavailable,
/// discovery returns without waiting and may start one cooldown-limited background retry. Healthy
/// servers keep their tools; a recovered server rejoins the catalog at the next discovery boundary.
/// Explicit refresh bypasses the cooldown and waits for the same bounded attempt.
public actor MCPManagedToolExecutor: ToolExecutor {
  private static let productionStartupTimeout: Duration = .seconds(5)
  private static let maximumStartupTimeout: Duration = .seconds(30)
  private static let productionRetryDelay: Duration = .seconds(30)

  private actor StartupRace {
    enum Outcome: Sendable {
      case started(availableToolCount: Int)
      case failed(MCPManagedToolFailure)
      case timedOut
      case cancelled
    }

    private enum State {
      case pending
      case stopping(Outcome)
      case resolved(Outcome)
    }

    private var state = State.pending
    private var continuation: CheckedContinuation<Outcome, Never>?

    func waitForOutcome() async -> Outcome {
      switch state {
      case .resolved(let outcome):
        return outcome
      case .pending, .stopping:
        return await withCheckedContinuation { continuation in
          if case .resolved(let outcome) = state {
            continuation.resume(returning: outcome)
          } else {
            self.continuation = continuation
          }
        }
      }
    }

    func resolve(_ outcome: Outcome) {
      guard case .pending = state else { return }
      finish(outcome)
    }

    func stopAndResolve(
      _ outcome: Outcome,
      executor: MCPToolExecutor
    ) async {
      guard case .pending = state else { return }
      state = .stopping(outcome)
      await executor.requestStop()
      finish(outcome)
    }

    private func finish(_ outcome: Outcome) {
      state = .resolved(outcome)
      let continuation = self.continuation
      self.continuation = nil
      continuation?.resume(returning: outcome)
    }
  }

  public nonisolated let serverID: String

  private let executor: MCPToolExecutor
  private let startupTimeout: Duration
  private let retryDelay: Duration
  private let waitsForInitialDiscovery: Bool
  private var state = MCPManagedToolExecutorState.disconnected
  private var failure: MCPManagedToolFailure?
  private var availableToolCount: Int?
  private var retryNotBefore: ContinuousClock.Instant?
  private var startup: (id: UUID, task: Task<Bool, any Error>, isBackground: Bool)?
  private var backgroundStartupWaiters:
    [UUID: (startupID: UUID, continuation: CheckedContinuation<Bool, any Error>)] = [:]
  private var catalogRefresh: (id: UUID, task: Task<Void, any Error>)?
  private var shutdown: (id: UUID, task: Task<Void, Never>)?
  private var catalogID: UUID?

  public init(session: any MCPClientSession) throws {
    try self.init(session: session, waitsForInitialDiscovery: true)
  }

  public init(session: any MCPClientSession, waitsForInitialDiscovery: Bool) throws {
    try self.init(
      session: session,
      startupTimeout: Self.productionStartupTimeout,
      waitsForInitialDiscovery: waitsForInitialDiscovery
    )
  }

  init(
    session: any MCPClientSession,
    startupTimeout: Duration,
    retryDelay: Duration = productionRetryDelay,
    waitsForInitialDiscovery: Bool = true
  ) throws {
    guard
      startupTimeout > .zero,
      startupTimeout <= Self.maximumStartupTimeout,
      retryDelay >= .zero,
      retryDelay <= .seconds(300)
    else {
      throw MCPToolExecutorError.invalidSession
    }
    serverID = session.serverID
    executor = try MCPToolExecutor(sessions: [session])
    self.startupTimeout = startupTimeout
    self.retryDelay = retryDelay
    self.waitsForInitialDiscovery = waitsForInitialDiscovery
  }

  public func availableTools() async throws -> [ToolDefinition] {
    try Task.checkCancellation()
    guard try await ensureStarted() else { return [] }
    let expectedCatalogID = catalogID
    do {
      let tools = try await executor.availableTools()
      guard state == .ready, catalogID == expectedCatalogID else { return [] }
      return tools
    } catch is CancellationError {
      if catalogID == expectedCatalogID {
        await invalidate(nextState: .disconnected)
      }
      throw CancellationError()
    } catch {
      if catalogID == expectedCatalogID {
        await invalidate(nextState: .unavailable, failure: .classify(error))
      }
      return []
    }
  }

  public func authorizationRequest(
    for call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> AuthorizationRequest {
    try Task.checkCancellation()
    guard state == .ready else {
      throw MCPToolExecutorError.notStarted
    }
    return try await executor.authorizationRequest(for: call, in: context)
  }

  public func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    try Task.checkCancellation()
    guard state == .ready else {
      throw MCPToolExecutorError.notStarted
    }
    let expectedCatalogID = catalogID
    let didDispatch = Mutex(false)
    do {
      return try await executor.execute(call, in: context) {
        didDispatch.withLock { $0 = true }
      }
    } catch is CancellationError {
      if catalogID == expectedCatalogID {
        await invalidate(nextState: .disconnected)
      }
      throw CancellationError()
    } catch {
      // A refreshed catalog may no longer expose the selected name. Only proven local refusal
      // preserves server health: a session can itself throw the same error after uncertain work.
      if error as? MCPToolExecutorError == .unknownTool, !didDispatch.withLock({ $0 }) {
        throw error
      }
      if catalogID == expectedCatalogID {
        await invalidate(nextState: .unavailable, failure: .classify(error))
      }
      throw error
    }
  }

  public func refreshCatalog() async throws {
    try Task.checkCancellation()
    guard shutdown == nil else { throw MCPToolExecutorError.transitionInProgress }
    if state != .ready {
      // A user waiting for explicit recovery must not put ordinary discovery back on the failed
      // server's critical path. Only a genuinely cold start is shared as a discovery wait.
      let attempt = startup ?? beginStartup(isBackground: state != .disconnected)
      guard try await waitForStartup(attempt) else {
        throw MCPToolExecutorError.notStarted
      }
      // Startup already retrieved and validated the complete catalog.
      return
    }
    let expectedCatalogID = catalogID
    let refresh = catalogRefresh?.task ?? beginCatalogRefresh()
    // This operation is shared. A cancelled observer does not cancel another caller's refresh.
    try await refresh.value
    try Task.checkCancellation()
    guard state == .ready, shutdown == nil, catalogID == expectedCatalogID else {
      throw MCPToolExecutorError.transitionInProgress
    }
  }

  private func beginCatalogRefresh() -> Task<Void, any Error> {
    let id = UUID()
    let expectedCatalogID = catalogID
    let task = Task {
      do {
        try await self.executor.refreshCatalog()
        let count = try await self.executor.availableTools().count
        try Task.checkCancellation()
        guard self.catalogRefresh?.id == id, self.catalogID == expectedCatalogID,
          self.state == .ready, self.shutdown == nil
        else {
          throw MCPToolExecutorError.transitionInProgress
        }
        self.availableToolCount = count
        self.catalogRefresh = nil
      } catch {
        // Clear ownership before invalidation so shutdown never tries to join this same task.
        if self.catalogRefresh?.id == id {
          self.catalogRefresh = nil
          if self.catalogID == expectedCatalogID {
            await self.invalidate(nextState: .unavailable, failure: .classify(error))
          }
        }
        throw error
      }
    }
    catalogRefresh = (id: id, task: task)
    return task
  }

  public func stop() async {
    await invalidate(nextState: .disconnected)
  }

  /// Starts only one owned cold attempt; does not wait for the server or bypass a failure cooldown.
  /// Stop joins/fences this attempt just like a discovery-owned retry.
  public func warmUp() {
    guard state == .disconnected, startup == nil, shutdown == nil else { return }
    _ = beginStartup(isBackground: true)
  }

  public func currentState() -> MCPManagedToolExecutorState {
    state
  }

  /// Reads only actor-owned metadata. Inspecting health never starts or refreshes a server.
  public func healthSnapshot() async -> MCPManagedToolExecutorSnapshot {
    MCPManagedToolExecutorSnapshot(
      serverID: serverID,
      state: state,
      failure: failure,
      availableToolCount: availableToolCount
    )
  }

  private func ensureStarted() async throws -> Bool {
    guard shutdown == nil else { return false }
    if state == .ready { return true }
    if let startup {
      if startup.isBackground { return false }
      return try await waitForStartup(startup)
    }
    if state == .unavailable {
      if retryNotBefore.map({ ContinuousClock.now >= $0 }) ?? true {
        _ = beginStartup(isBackground: true)
      }
      return false
    }
    let attempt = beginStartup(isBackground: !waitsForInitialDiscovery)
    return waitsForInitialDiscovery ? try await waitForStartup(attempt) : false
  }

  private func beginStartup(
    isBackground: Bool
  ) -> (id: UUID, task: Task<Bool, any Error>, isBackground: Bool) {
    let id = UUID()
    state = .connecting
    failure = nil
    availableToolCount = nil
    let task = Task {
      do {
        let outcome = try await self.startBeforeDeadline()
        return self.finishStartup(id: id, outcome: outcome)
      } catch {
        _ = self.finishStartup(
          id: id,
          outcome: error is CancellationError ? .cancelled : .failed(.classify(error)))
        throw error
      }
    }
    let attempt = (id: id, task: task, isBackground: isBackground)
    startup = attempt
    return attempt
  }

  private func finishStartup(id: UUID, outcome: StartupRace.Outcome) -> Bool {
    // A stopped or replaced attempt must never publish a late ready catalog.
    guard startup?.id == id, shutdown == nil else { return false }
    startup = nil
    let started: Bool
    let cancelled: Bool
    switch outcome {
    case .started(let count):
      started = true
      cancelled = false
      state = .ready
      failure = nil
      availableToolCount = count
    case .failed(let reason):
      started = false
      cancelled = false
      state = .unavailable
      failure = reason
      availableToolCount = nil
    case .timedOut:
      started = false
      cancelled = false
      state = .unavailable
      failure = .connectionTimedOut
      availableToolCount = nil
    case .cancelled:
      started = false
      cancelled = true
      state = .disconnected
      failure = nil
      availableToolCount = nil
    }
    catalogID = started ? id : nil
    retryNotBefore = started || cancelled ? nil : ContinuousClock.now.advanced(by: retryDelay)
    finishBackgroundStartupWaiters(
      startupID: id,
      result: cancelled ? .failure(CancellationError()) : .success(started))
    return started
  }

  private func waitForStartup(
    _ attempt: (id: UUID, task: Task<Bool, any Error>, isBackground: Bool)
  ) async throws -> Bool {
    if attempt.isBackground {
      return try await observeBackgroundStartup(id: attempt.id)
    }
    let task = attempt.task
    let started = try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
    try Task.checkCancellation()
    return started && state == .ready && shutdown == nil
  }

  private func observeBackgroundStartup(id: UUID) async throws -> Bool {
    let waiterID = UUID()
    let started = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Bool, any Error>) in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        guard startup?.id == id else {
          continuation.resume(returning: state == .ready && catalogID == id && shutdown == nil)
          return
        }
        backgroundStartupWaiters[waiterID] = (id, continuation)
      }
    } onCancel: {
      Task { await self.cancelBackgroundStartupWaiter(id: waiterID) }
    }
    try Task.checkCancellation()
    return started && state == .ready && catalogID == id && shutdown == nil
  }

  private func cancelBackgroundStartupWaiter(id: UUID) {
    backgroundStartupWaiters.removeValue(forKey: id)?.continuation.resume(
      throwing: CancellationError())
  }

  private func finishBackgroundStartupWaiters(
    startupID: UUID, result: Result<Bool, any Error>
  ) {
    let identifiers = backgroundStartupWaiters.compactMap { id, waiter in
      waiter.startupID == startupID ? id : nil
    }
    for id in identifiers {
      backgroundStartupWaiters.removeValue(forKey: id)?.continuation.resume(with: result)
    }
  }

  private func startBeforeDeadline() async throws -> StartupRace.Outcome {
    try Task.checkCancellation()
    let race = StartupRace()
    let executor = self.executor
    let startupTimeout = self.startupTimeout
    let startupTask = Task {
      do {
        try await executor.start()
        let count = try await executor.availableTools().count
        await race.resolve(.started(availableToolCount: count))
      } catch {
        await race.resolve(.failed(.classify(error)))
      }
    }
    let timeoutTask = Task {
      do {
        try await Task.sleep(for: startupTimeout)
      } catch {
        return
      }
      await race.stopAndResolve(.timedOut, executor: executor)
    }

    let outcome = await withTaskCancellationHandler {
      await race.waitForOutcome()
    } onCancel: {
      Task {
        await race.stopAndResolve(.cancelled, executor: executor)
      }
    }
    timeoutTask.cancel()
    startupTask.cancel()

    switch outcome {
    case .started:
      do {
        try Task.checkCancellation()
        return outcome
      } catch {
        await executor.requestStop()
        throw CancellationError()
      }
    case .failed:
      do {
        try Task.checkCancellation()
        return outcome
      } catch {
        await executor.requestStop()
        throw CancellationError()
      }
    case .timedOut:
      try Task.checkCancellation()
      return outcome
    case .cancelled:
      throw CancellationError()
    }
  }

  private func invalidate(
    nextState: MCPManagedToolExecutorState,
    failure: MCPManagedToolFailure? = nil
  ) async {
    state = nextState
    self.failure = nextState == .unavailable ? failure ?? .connectionFailed : nil
    availableToolCount = nil
    catalogID = nil
    retryNotBefore = nextState == .unavailable ? ContinuousClock.now.advanced(by: retryDelay) : nil
    if let shutdown {
      await shutdown.task.value
      return
    }
    let pendingStartup = startup
    startup = nil
    pendingStartup?.task.cancel()
    if let pendingStartup {
      finishBackgroundStartupWaiters(
        startupID: pendingStartup.id, result: .failure(CancellationError()))
    }
    let pendingRefresh = catalogRefresh?.task
    catalogRefresh = nil
    pendingRefresh?.cancel()
    let id = UUID()
    let task = Task {
      if let pendingRefresh {
        // Invalidate the underlying generation before joining a server that ignores cancellation.
        await self.executor.requestStop()
        _ = await pendingRefresh.result
      }
      if let pendingStartup { _ = await pendingStartup.task.result }
      // Join the underlying session cleanup too, including a startup that exceeded its deadline.
      await self.executor.stop()
      self.finishShutdown(id: id)
    }
    shutdown = (id: id, task: task)
    await task.value
  }

  private func finishShutdown(id: UUID) {
    guard shutdown?.id == id else { return }
    shutdown = nil
  }
}
