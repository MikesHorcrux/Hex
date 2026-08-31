import HexCore

extension HexGatewayService {
  public func startRun(
    _ untrustedRequest: GatewayStartRunRequest,
    sessionID untrustedSessionID: GatewaySessionID
  ) throws -> GatewayStartRunResponse {
    let sessionID = try codec.roundTrip(untrustedSessionID)
    let request = try codec.roundTrip(untrustedRequest)
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
      return try codec.roundTrip(
        GatewayStartRunResponse(runID: request.runID, disposition: disposition)
      )
    }

    if let activeRunID {
      return try codec.roundTrip(
        GatewayStartRunResponse(
          runID: request.runID,
          disposition: .busy(activeRunID: activeRunID)
        )
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

    let response = try codec.roundTrip(
      GatewayStartRunResponse(runID: request.runID, disposition: .started)
    )
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
    return response
  }

  public func cancelRun(
    _ untrustedRequest: GatewayCancelRunRequest,
    sessionID untrustedSessionID: GatewaySessionID
  ) throws -> GatewayCancelRunResponse {
    let sessionID = try codec.roundTrip(untrustedSessionID)
    let request = try codec.roundTrip(untrustedRequest)
    try requireSession(sessionID)

    guard var state = runs[request.runID] else {
      return try codec.roundTrip(
        GatewayCancelRunResponse(runID: request.runID, disposition: .notFound)
      )
    }

    guard state.phase != .terminal else {
      return try codec.roundTrip(
        GatewayCancelRunResponse(runID: request.runID, disposition: .alreadyTerminal)
      )
    }

    let response = try codec.roundTrip(
      GatewayCancelRunResponse(runID: request.runID, disposition: .requested)
    )
    state.phase = .cancelling
    let task = state.task
    runs[request.runID] = state
    task?.cancel()

    return response
  }

  func driverFinished(runID: AgentRunID) {
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
    finishRunOwnership(runID)
  }

  func driverCancelled(runID: AgentRunID) {
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

  func driverFailed(runID: AgentRunID, failure: GatewayFailure) {
    guard let state = runs[runID] else {
      return
    }
    if state.terminalSequence == nil, state.completionFailure == nil {
      failRun(runID, with: failure)
    }
    driverFinished(runID: runID)
  }

  func failRun(_ runID: AgentRunID, with failure: GatewayFailure) {
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

  func finishRunOwnership(_ runID: AgentRunID) {
    if activeRunID == runID {
      activeRunID = nil
    }
    rememberCompletedRun(runID)
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
