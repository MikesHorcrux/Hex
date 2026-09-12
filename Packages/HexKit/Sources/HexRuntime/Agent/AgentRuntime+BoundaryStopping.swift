import HexCore

extension AgentRuntime {
  /// May arrive just before admission. Identity-scoped and consumed when that attempt exits.
  public func stopAtBoundary(_ runID: AgentRunID) {
    boundaryStops.insert(runID)
    boundaryAuthorizations[runID]?.cancel()
    boundaryInferences[runID]?()
  }

  /// Provider generation has no tool side effects. Stop and join only that work, leaving
  /// already-dispatched tools under the existing receipt-preserving boundary protocol.
  func inferenceAtBoundary<Result: Sendable>(
    _ runID: AgentRunID, operation: @escaping @Sendable () async throws -> Result
  ) async throws -> Result {
    try checkBoundaryStop(runID)
    let task = Task { try await operation() }
    boundaryInferences[runID] = { task.cancel() }
    defer { boundaryInferences.removeValue(forKey: runID) }
    return try await withTaskCancellationHandler {
      let result = try await task.value
      try checkBoundaryStop(runID)
      return result
    } onCancel: {
      task.cancel()
    }
  }

  func authorizeAtBoundary(_ request: AuthorizationRequest) async throws -> AuthorizationDecision {
    try checkBoundaryStop(request.runID)
    let provider = authorizationProvider
    let task = Task { try await provider.authorize(request) }
    boundaryAuthorizations[request.runID] = task
    defer { boundaryAuthorizations.removeValue(forKey: request.runID) }
    return try await withTaskCancellationHandler {
      let decision = try await task.value
      try checkBoundaryStop(request.runID)
      return decision
    } onCancel: {
      task.cancel()
    }
  }

  func checkBoundaryStop(_ runID: AgentRunID) throws {
    try Task.checkCancellation()
    if boundaryStops.contains(runID) { throw CancellationError() }
  }
}
