import HexCore

extension HexGatewayService {
  public func startRun(
    _ untrustedRequest: GatewayStartRunRequest,
    sessionID untrustedSessionID: GatewaySessionID
  ) throws -> GatewayStartRunResponse {
    let sessionID = try codec.roundTrip(untrustedSessionID)
    let request = try codec.roundTrip(untrustedRequest)
    try requireSession(sessionID)
    try requireValidGatewayIdentity(
      request.runID.rawValue,
      message: "The gateway start request contains an invalid run identity."
    )

    if let existingState = runs[request.runID] {
      guard existingState.request == request else {
        throw GatewayFailure(
          code: .conflictingRunRequest,
          message: "The run identifier was already used with different request content."
        )
      }

      let disposition: GatewayStartRunDisposition =
        existingState.phase == .terminal
        ? .alreadyTerminal(invocationID: existingState.invocationID)
        : .alreadyRunning(invocationID: existingState.invocationID)
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

    // The server issues an invocation identity only after the request has passed conflict, active-run,
    // and capacity admission. Exact duplicate starts are idempotent only while their run remains in
    // the bounded remembered set; after eviction, the same request starts a fresh invocation.
    let invocationID = GatewayRunInvocationID()
    let response = try codec.roundTrip(
      GatewayStartRunResponse(
        runID: request.runID,
        disposition: .started(invocationID: invocationID)
      )
    )
    let state = GatewayRunState(request: request, invocationID: invocationID)
    activeRunID = request.runID
    runs[request.runID] = state

    let driver = self.driver
    let task = Task { [driver, invocationID, request] in
      do {
        try await driver.run(request) { record in
          try await self.accept(
            record,
            for: request.runID,
            invocationID: invocationID
          )
        }
        self.driverFinished(runID: request.runID, invocationID: invocationID)
      } catch is CancellationError {
        self.driverCancelled(runID: request.runID, invocationID: invocationID)
      } catch let failure as GatewayFailure {
        self.driverFailed(
          runID: request.runID,
          invocationID: invocationID,
          failure: failure
        )
      } catch {
        self.driverFailed(
          runID: request.runID,
          invocationID: invocationID,
          failure: GatewayFailure(
            code: .runDriverFailed,
            message: "The gateway run driver failed."
          )
        )
      }
    }

    if var installedState = runs[request.runID],
      installedState.invocationID == invocationID
    {
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
    try requireValidGatewayIdentity(
      request.runID.rawValue,
      message: "The gateway cancellation request contains an invalid run identity."
    )
    try requireValidGatewayIdentity(
      request.invocationID.rawValue,
      message: "The gateway cancellation request contains an invalid invocation identity."
    )

    guard var state = runs[request.runID] else {
      return try codec.roundTrip(
        GatewayCancelRunResponse(
          runID: request.runID,
          invocationID: request.invocationID,
          disposition: .notFound
        )
      )
    }

    guard state.invocationID == request.invocationID else {
      throw GatewayFailure(
        code: .staleRunInvocation,
        message: "The cancellation targets a stale run invocation."
      )
    }

    guard state.phase != .terminal else {
      return try codec.roundTrip(
        GatewayCancelRunResponse(
          runID: request.runID,
          invocationID: state.invocationID,
          disposition: .alreadyTerminal
        )
      )
    }

    let response = try codec.roundTrip(
      GatewayCancelRunResponse(
        runID: request.runID,
        invocationID: state.invocationID,
        disposition: .requested
      )
    )
    state.phase = .cancelling
    let task = state.task
    runs[request.runID] = state
    task?.cancel()

    return response
  }

  func driverFinished(runID: AgentRunID, invocationID: GatewayRunInvocationID) {
    guard var state = runs[runID], state.invocationID == invocationID else {
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
        invocationID: invocationID,
        with: GatewayFailure(
          code: .producerEndedWithoutTerminalEvent,
          message: "The run driver ended without emitting a terminal event."
        )
      )
    }
    finishRunOwnership(runID, invocationID: invocationID)
  }

  func driverCancelled(runID: AgentRunID, invocationID: GatewayRunInvocationID) {
    guard let state = runs[runID], state.invocationID == invocationID else {
      return
    }
    if state.terminalSequence == nil, state.completionFailure == nil {
      failRun(
        runID,
        invocationID: invocationID,
        with: GatewayFailure(
          code: .producerEndedWithoutTerminalEvent,
          message: "The cancelled run ended without a durable runCancelled event."
        )
      )
    }
    driverFinished(runID: runID, invocationID: invocationID)
  }

  func driverFailed(
    runID: AgentRunID,
    invocationID: GatewayRunInvocationID,
    failure: GatewayFailure
  ) {
    guard let state = runs[runID], state.invocationID == invocationID else {
      return
    }
    if state.terminalSequence == nil, state.completionFailure == nil {
      failRun(runID, invocationID: invocationID, with: failure)
    }
    driverFinished(runID: runID, invocationID: invocationID)
  }

  func failRun(
    _ runID: AgentRunID,
    invocationID: GatewayRunInvocationID,
    with untrustedFailure: GatewayFailure
  ) {
    guard var state = runs[runID], state.invocationID == invocationID else {
      return
    }

    let failure = codec.canonicalFailure(from: untrustedFailure)
    state.phase = .terminal
    state.completionFailure = failure
    let task = state.task
    for subscriber in state.subscribers.values {
      subscriber.continuation.finish(throwing: failure)
    }
    state.subscribers.removeAll()
    runs[runID] = state
    finishRunOwnership(runID, invocationID: invocationID)
    task?.cancel()
  }

  func finishRunOwnership(_ runID: AgentRunID, invocationID: GatewayRunInvocationID) {
    guard let state = runs[runID], state.invocationID == invocationID else {
      return
    }
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
