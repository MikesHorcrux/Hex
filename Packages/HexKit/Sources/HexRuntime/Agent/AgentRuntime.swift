import HexCore

public actor AgentRuntime {
  let inferenceProvider: any InferenceProvider
  let toolExecutor: any ToolExecutor
  let authorizationProvider: any AuthorizationProvider
  let journal: any AgentEventJournal
  let configuration: AgentRuntimeConfiguration

  private var activeRunIDs: Set<AgentRunID> = []
  private var authorizationScopeRunIDs: Set<AgentRunID> = []
  var runsWithStartedTools: Set<AgentRunID> = []

  public init(
    inferenceProvider: any InferenceProvider,
    toolExecutor: any ToolExecutor,
    authorizationProvider: any AuthorizationProvider,
    journal: any AgentEventJournal,
    configuration: AgentRuntimeConfiguration = AgentRuntimeConfiguration()
  ) {
    self.inferenceProvider = inferenceProvider
    self.toolExecutor = toolExecutor
    self.authorizationProvider = authorizationProvider
    self.journal = journal
    self.configuration = configuration
  }

  public func run(_ request: AgentRunRequest) async throws -> AgentRunResult {
    guard activeRunIDs.insert(request.runID).inserted else {
      throw AgentRuntimeError.duplicateRun(request.runID)
    }
    defer {
      activeRunIDs.remove(request.runID)
      authorizationScopeRunIDs.remove(request.runID)
      runsWithStartedTools.remove(request.runID)
    }

    do {
      let result = try await performRun(request)
      await endAuthorizationScopeIfOwned(for: request.runID)
      return result
    } catch is CancellationError {
      await endAuthorizationScopeIfOwned(for: request.runID)
      throw CancellationError()
    } catch let error as AgentRuntimeError {
      await endAuthorizationScopeIfOwned(for: request.runID)
      throw error
    } catch {
      await endAuthorizationScopeIfOwned(for: request.runID)
      throw AgentRuntimeError.invalidState("The runtime encountered an unexpected failure.")
    }
  }

  private func performRun(_ request: AgentRunRequest) async throws -> AgentRunResult {
    var didStart = false
    do {
      try configuration.budget.validate()
      try validateRequest(request)
      let model = try await loadModel(for: request)
      try validate(request: request, against: model)
      try await requireUnusedRunID(request.runID)

      try await append(.runStarted, to: request.runID)
      authorizationScopeRunIDs.insert(request.runID)
      didStart = true
      for message in request.initialMessages {
        try await append(.messageAppended(message), to: request.runID)
      }

      return try await execute(request, model: model)
    } catch is CancellationError {
      if didStart {
        try await appendTerminal(.runCancelled, to: request.runID)
      }
      throw CancellationError()
    } catch let error as AgentRuntimeError {
      if didStart {
        let isRetryable = !runsWithStartedTools.contains(request.runID)
        try await appendTerminal(
          .runFailed(error.agentFailure(isRetryable: isRetryable)),
          to: request.runID
        )
      }
      throw error
    } catch {
      let error = AgentRuntimeError.invalidState("The runtime encountered an unexpected failure.")
      if didStart {
        try await appendTerminal(
          .runFailed(
            error.agentFailure(
              isRetryable: !runsWithStartedTools.contains(request.runID)
            )
          ),
          to: request.runID
        )
      }
      throw error
    }
  }

  private func endAuthorizationScopeIfOwned(for runID: AgentRunID) async {
    guard authorizationScopeRunIDs.remove(runID) != nil else {
      return
    }
    await authorizationProvider.endRun(runID)
  }
}
