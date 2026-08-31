import Foundation
import HexCore

/// The sole mutable owner of gateway sessions, run lifecycle, replay buffers, and live subscribers.
/// It runs in the caller's process and provides no XPC boundary, service installation, persistence
/// across app termination, sandbox escape, or additional filesystem/terminal authority.
public actor HexGatewayService {
  private let driver: any HexGatewayRunDriver
  private let configuration: GatewayConfiguration
  private let gatewayInstanceID: GatewayInstanceID
  private var sessions: [GatewaySessionID: GatewaySessionState] = [:]
  private var runs: [AgentRunID: GatewayRunState] = [:]
  private var completedRunOrder: [AgentRunID] = []
  private var activeRunID: AgentRunID?

  public init(
    driver: any HexGatewayRunDriver,
    configuration: GatewayConfiguration = .standard,
    gatewayInstanceID: GatewayInstanceID = GatewayInstanceID()
  ) {
    self.driver = driver
    self.configuration = configuration
    self.gatewayInstanceID = gatewayInstanceID
  }

  public func handshake(_ request: GatewayHandshakeRequest) throws -> GatewayHandshakeResponse {
    guard request.minimumVersion <= request.maximumVersion else {
      throw GatewayFailure(
        code: .malformedVersionRange,
        message: "The gateway protocol version range is malformed."
      )
    }

    let lowerBound =
      request.minimumVersion > GatewayProtocolVersion.minimumSupported
      ? request.minimumVersion
      : GatewayProtocolVersion.minimumSupported
    let upperBound =
      request.maximumVersion < GatewayProtocolVersion.current
      ? request.maximumVersion
      : GatewayProtocolVersion.current

    guard lowerBound <= upperBound else {
      throw GatewayFailure(
        code: .incompatibleProtocolVersion,
        message: "The client and gateway do not share a supported protocol version."
      )
    }

    guard sessions.count < configuration.maximumSessions else {
      throw GatewayFailure(
        code: .capacityExceeded,
        message: "The gateway has reached its configured active-session limit.",
        isRetryable: true
      )
    }

    let sessionID = GatewaySessionID()
    sessions[sessionID] = GatewaySessionState(
      clientID: request.clientID,
      selectedVersion: upperBound
    )

    return GatewayHandshakeResponse(
      sessionID: sessionID,
      gatewayInstanceID: gatewayInstanceID,
      selectedVersion: upperBound,
      activeRun: activeRunSnapshot()
    )
  }

  public func startRun(
    _ request: GatewayStartRunRequest,
    sessionID: GatewaySessionID
  ) throws -> GatewayStartRunResponse {
    try requireSession(sessionID)

    if let existingState = runs[request.runID] {
      guard existingState.request == request else {
        throw GatewayFailure(
          code: .conflictingRunRequest,
          message: "The run identifier was already used with different request content."
        )
      }

      let disposition: GatewayStartRunDisposition =
        existingState.phase == .terminal ? .alreadyTerminal : .alreadyRunning
      return GatewayStartRunResponse(runID: request.runID, disposition: disposition)
    }

    if let activeRunID {
      return GatewayStartRunResponse(
        runID: request.runID,
        disposition: .busy(activeRunID: activeRunID)
      )
    }

    evictCompletedRunsToMakeRoom()
    guard runs.count < configuration.maximumRememberedRuns else {
      throw GatewayFailure(
        code: .capacityExceeded,
        message: "The gateway has reached its configured remembered-run limit.",
        isRetryable: true
      )
    }

    let state = GatewayRunState(request: request)
    activeRunID = request.runID
    runs[request.runID] = state

    let driver = self.driver
    let task = Task { [driver, request] in
      do {
        try await driver.run(request) { record in
          try await self.accept(record, for: request.runID)
        }
        self.driverFinished(runID: request.runID)
      } catch is CancellationError {
        self.driverCancelled(runID: request.runID)
      } catch let failure as GatewayFailure {
        self.driverFailed(runID: request.runID, failure: failure)
      } catch {
        self.driverFailed(
          runID: request.runID,
          failure: GatewayFailure(
            code: .runDriverFailed,
            message: "The gateway run driver failed."
          )
        )
      }
    }

    if var installedState = runs[request.runID] {
      installedState.task = task
      runs[request.runID] = installedState
    }
    return GatewayStartRunResponse(runID: request.runID, disposition: .started)
  }

  public func cancelRun(
    _ request: GatewayCancelRunRequest,
    sessionID: GatewaySessionID
  ) throws -> GatewayCancelRunResponse {
    try requireSession(sessionID)

    guard var state = runs[request.runID] else {
      return GatewayCancelRunResponse(runID: request.runID, disposition: .notFound)
    }

    guard state.phase != .terminal else {
      return GatewayCancelRunResponse(runID: request.runID, disposition: .alreadyTerminal)
    }

    state.phase = .cancelling
    let task = state.task
    runs[request.runID] = state
    task?.cancel()

    return GatewayCancelRunResponse(runID: request.runID, disposition: .requested)
  }

  /// Atomically enqueues retained records and installs the live subscriber without an actor
  /// suspension point, preventing an event from falling between replay and live delivery.
  public func eventRecords(
    after cursor: GatewayEventCursor,
    sessionID: GatewaySessionID
  ) throws -> AsyncThrowingStream<AgentEventRecord, any Error> {
    try requireSession(sessionID)

    guard var state = runs[cursor.runID] else {
      throw GatewayFailure(
        code: .runNotFound,
        message: "The requested run is unavailable in this gateway instance."
      )
    }

    guard cursor.sequence <= state.latestSequence else {
      throw GatewayFailure(
        code: .invalidCursor,
        message: "The event cursor is ahead of the gateway high-water mark."
      )
    }

    if let firstRetainedSequence = state.retainedRecords.first?.sequence,
      cursor.sequence < firstRetainedSequence - 1
    {
      throw GatewayFailure(
        code: .replayUnavailable,
        message: "The requested event cursor predates the retained replay window."
      )
    }

    let pair = AsyncThrowingStream<AgentEventRecord, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(configuration.subscriberBufferCapacity)
    )
    let stream = pair.stream
    let continuation = pair.continuation

    for record in state.retainedRecords where record.sequence > cursor.sequence {
      guard enqueue(record, into: continuation) else {
        continuation.finish(
          throwing: GatewayFailure(
            code: .consumerTooSlow,
            message: "The event consumer could not accept the retained replay window.",
            isRetryable: true
          )
        )
        return stream
      }
    }

    if let completionFailure = state.completionFailure {
      continuation.finish(throwing: completionFailure)
      return stream
    }

    if state.phase == .terminal, state.task == nil {
      continuation.finish()
      return stream
    }

    guard state.subscribers.count < configuration.maximumSubscribersPerRun else {
      continuation.finish(
        throwing: GatewayFailure(
          code: .capacityExceeded,
          message: "The run has reached its configured live-subscriber limit.",
          isRetryable: true
        )
      )
      return stream
    }

    let subscriberID = UUID()
    state.subscribers[subscriberID] = GatewaySubscriber(
      sessionID: sessionID,
      continuation: continuation
    )
    runs[cursor.runID] = state

    continuation.onTermination = { @Sendable [weak self] _ in
      Task {
        await self?.removeSubscriber(runID: cursor.runID, subscriberID: subscriberID)
      }
    }

    return stream
  }

  public func disconnect(sessionID: GatewaySessionID) {
    guard sessions.removeValue(forKey: sessionID) != nil else {
      return
    }

    let failure = GatewayFailure(
      code: .disconnected,
      message: "The gateway session disconnected.",
      isRetryable: true
    )

    let runIDs = Array(runs.keys)
    for runID in runIDs {
      guard var state = runs[runID] else {
        continue
      }

      let disconnectedSubscriberIDs = state.subscribers.compactMap { entry in
        entry.value.sessionID == sessionID ? entry.key : nil
      }
      for subscriberID in disconnectedSubscriberIDs {
        state.subscribers.removeValue(forKey: subscriberID)?.continuation.finish(
          throwing: failure
        )
      }
      runs[runID] = state
    }
  }

  private func requireSession(_ sessionID: GatewaySessionID) throws {
    guard sessions[sessionID] != nil else {
      throw GatewayFailure(
        code: .staleSession,
        message: "The gateway session is missing or no longer active.",
        isRetryable: true
      )
    }
  }

  private func activeRunSnapshot() -> GatewayRunSnapshot? {
    guard let activeRunID, let state = runs[activeRunID] else {
      return nil
    }
    return GatewayRunSnapshot(
      runID: activeRunID,
      phase: state.phase,
      latestSequence: state.latestSequence
    )
  }

  private func accept(_ record: AgentEventRecord, for runID: AgentRunID) throws {
    guard var state = runs[runID] else {
      throw GatewayFailure(
        code: .runNotFound,
        message: "The run driver emitted an event for an unknown run."
      )
    }

    guard record.runID == runID else {
      let failure = GatewayFailure(
        code: .wrongRun,
        message: "The run driver emitted a record for the wrong run."
      )
      failRun(runID, with: failure)
      throw failure
    }

    guard state.terminalSequence == nil else {
      let failure = GatewayFailure(
        code: .eventAfterTerminal,
        message: "The run driver emitted a record after a terminal event."
      )
      failRun(runID, with: failure)
      throw failure
    }

    guard record.schemaVersion == 1 else {
      let failure = GatewayFailure(
        code: .unsupportedEventSchema,
        message: "The event record schema version is unsupported."
      )
      failRun(runID, with: failure)
      throw failure
    }

    let nextSequence = state.latestSequence.addingReportingOverflow(1)
    guard !nextSequence.overflow, record.sequence == nextSequence.partialValue else {
      let failure = GatewayFailure(
        code: .invalidEventSequence,
        message: "The run driver emitted a duplicate, missing, or overflowing sequence."
      )
      failRun(runID, with: failure)
      throw failure
    }

    if record.sequence == 1 {
      guard case .runStarted = record.event else {
        let failure = GatewayFailure(
          code: .invalidEventSequence,
          message: "The first run event must be runStarted."
        )
        failRun(runID, with: failure)
        throw failure
      }
    } else if case .runStarted = record.event {
      let failure = GatewayFailure(
        code: .invalidEventSequence,
        message: "A run may emit runStarted only once."
      )
      failRun(runID, with: failure)
      throw failure
    }

    state.latestSequence = record.sequence
    state.phase = isTerminal(record.event) ? .terminal : .running
    if state.phase == .terminal {
      state.terminalSequence = record.sequence
    }

    state.retainedRecords.append(record)
    let excessRecordCount =
      state.retainedRecords.count - configuration.maximumRetainedRecordsPerRun
    if excessRecordCount > 0 {
      state.retainedRecords.removeFirst(excessRecordCount)
    }

    let slowConsumerFailure = GatewayFailure(
      code: .consumerTooSlow,
      message: "The event consumer fell behind the bounded gateway buffer.",
      isRetryable: true
    )
    var subscribersToRemove: [UUID] = []
    for (subscriberID, subscriber) in state.subscribers {
      guard enqueue(record, into: subscriber.continuation) else {
        subscriber.continuation.finish(throwing: slowConsumerFailure)
        subscribersToRemove.append(subscriberID)
        continue
      }
    }
    for subscriberID in subscribersToRemove {
      state.subscribers.removeValue(forKey: subscriberID)
    }

    runs[runID] = state
  }

  private func enqueue(
    _ record: AgentEventRecord,
    into continuation: AsyncThrowingStream<AgentEventRecord, any Error>.Continuation
  ) -> Bool {
    switch continuation.yield(record) {
    case .enqueued:
      return true
    case .dropped, .terminated:
      return false
    @unknown default:
      return false
    }
  }

  private func isTerminal(_ event: AgentEvent) -> Bool {
    switch event {
    case .runCompleted, .runCancelled, .runFailed:
      true
    default:
      false
    }
  }

  private func removeSubscriber(runID: AgentRunID, subscriberID: UUID) {
    guard var state = runs[runID] else {
      return
    }
    state.subscribers.removeValue(forKey: subscriberID)
    runs[runID] = state
  }

  private func driverFinished(runID: AgentRunID) {
    guard var state = runs[runID] else {
      return
    }

    if state.terminalSequence != nil, state.completionFailure == nil {
      for subscriber in state.subscribers.values {
        subscriber.continuation.finish()
      }
      state.subscribers.removeAll()
    }
    state.task = nil
    runs[runID] = state
    if state.terminalSequence == nil, state.completionFailure == nil {
      failRun(
        runID,
        with: GatewayFailure(
          code: .producerEndedWithoutTerminalEvent,
          message: "The run driver ended without emitting a terminal event."
        )
      )
    }
    if activeRunID == runID {
      activeRunID = nil
    }
    rememberCompletedRun(runID)
  }

  private func driverCancelled(runID: AgentRunID) {
    guard let state = runs[runID] else {
      return
    }
    if state.terminalSequence == nil, state.completionFailure == nil {
      failRun(
        runID,
        with: GatewayFailure(
          code: .producerEndedWithoutTerminalEvent,
          message: "The cancelled run ended without a durable runCancelled event."
        )
      )
    }
    driverFinished(runID: runID)
  }

  private func driverFailed(runID: AgentRunID, failure: GatewayFailure) {
    guard let state = runs[runID] else {
      return
    }
    if state.terminalSequence == nil, state.completionFailure == nil {
      failRun(runID, with: failure)
    }
    driverFinished(runID: runID)
  }

  private func failRun(_ runID: AgentRunID, with failure: GatewayFailure) {
    guard var state = runs[runID] else {
      return
    }

    state.phase = .terminal
    state.completionFailure = failure
    let task = state.task
    for subscriber in state.subscribers.values {
      subscriber.continuation.finish(throwing: failure)
    }
    state.subscribers.removeAll()
    runs[runID] = state
    task?.cancel()
  }

  private func rememberCompletedRun(_ runID: AgentRunID) {
    if !completedRunOrder.contains(runID) {
      completedRunOrder.append(runID)
    }
    evictCompletedRunsToFitLimit()
  }

  private func evictCompletedRunsToMakeRoom() {
    while runs.count >= configuration.maximumRememberedRuns,
      let runID = completedRunOrder.first
    {
      completedRunOrder.removeFirst()
      runs.removeValue(forKey: runID)
    }
  }

  private func evictCompletedRunsToFitLimit() {
    while runs.count > configuration.maximumRememberedRuns,
      let runID = completedRunOrder.first
    {
      completedRunOrder.removeFirst()
      runs.removeValue(forKey: runID)
    }
  }
}
