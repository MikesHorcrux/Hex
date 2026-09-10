import HexCore

public actor AgentRuntime {
  let inferenceProvider: any InferenceProvider
  let toolExecutor: any ToolExecutor
  let authorizationProvider: any AuthorizationProvider
  let journal: any AgentEventJournal
  let configuration: AgentRuntimeConfiguration
  let contextEstimator: any AgentContextTokenEstimating
  let contextSummarizer: any AgentContextSummarizing
  let artifactWriter: (any ArtifactWriting)?
  var boundaryAuthorizations: [AgentRunID: Task<AuthorizationDecision, any Error>] = [:]
  var boundaryInferences: [AgentRunID: @Sendable () -> Void] = [:]
  var boundaryStops: Set<AgentRunID> = []
  var runArtifacts: [AgentRunID: [ArtifactReference]] = [:]
  // Immutable for each run: changing an earlier host message would invalidate provider replay.
  var runArtifactContextMessages: [AgentRunID: Message] = [:]

  private var activeRunIDs: Set<AgentRunID> = []
  private var authorizationScopeRunIDs: Set<AgentRunID> = []
  var runsWithStartedTools: Set<AgentRunID> = []
  var runToolDispatchLedgers: [AgentRunID: AgentToolDispatchLedger] = [:]

  public init(
    inferenceProvider: any InferenceProvider,
    toolExecutor: any ToolExecutor,
    authorizationProvider: any AuthorizationProvider,
    journal: any AgentEventJournal,
    configuration: AgentRuntimeConfiguration = AgentRuntimeConfiguration(),
    contextEstimator: any AgentContextTokenEstimating = ConservativeAgentContextTokenEstimator(),
    contextSummarizer: (any AgentContextSummarizing)? = nil,
    artifactWriter: (any ArtifactWriting)? = nil
  ) {
    self.inferenceProvider = inferenceProvider
    self.toolExecutor = toolExecutor
    self.authorizationProvider = authorizationProvider
    self.journal = journal
    self.configuration = configuration
    self.contextEstimator = contextEstimator
    self.artifactWriter = artifactWriter
    self.contextSummarizer =
      contextSummarizer
      ?? InferenceAgentContextSummarizer(
        provider: inferenceProvider, estimator: contextEstimator,
        maximumCalls: configuration.context.maximumSummaryCalls,
        fallbackContextWindow: configuration.context.fallbackContextWindow,
        safetyMarginTokens: configuration.context.safetyMarginTokens)
  }

  public func run(_ request: AgentRunRequest) async throws -> AgentRunResult {
    guard activeRunIDs.insert(request.runID).inserted else {
      throw AgentRuntimeError.duplicateRun(request.runID)
    }
    defer {
      activeRunIDs.remove(request.runID)
      boundaryStops.remove(request.runID)
      authorizationScopeRunIDs.remove(request.runID)
      runsWithStartedTools.remove(request.runID)
      runArtifacts.removeValue(forKey: request.runID)
      runArtifactContextMessages.removeValue(forKey: request.runID)
      runToolDispatchLedgers.removeValue(forKey: request.runID)
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
      try configuration.context.validate()
      try validateRequest(request)
      try prepareArtifactInventory(for: request)
      let model = try await loadModel(for: request)
      try validate(request: request, against: model)
      try await requireUnusedRunID(request.runID)

      try await append(.runStarted, to: request.runID)
      authorizationScopeRunIDs.insert(request.runID)
      didStart = true
      do {
        try await authorizationProvider.beginRun(
          request.runID, authorizationMode: request.authorizationMode)
      } catch is CancellationError {
        throw CancellationError()
      } catch AuthorizationPolicyError.unsupportedOverride {
        if Task.isCancelled { throw CancellationError() }
        throw AgentRuntimeError.authorizationFailure(
          "This gateway cannot apply conversation-specific permissions. Update its authorization integration before sending this request."
        )
      } catch {
        if Task.isCancelled { throw CancellationError() }
        throw AgentRuntimeError.authorizationFailure(
          "The run's approval policy could not be established safely.")
      }
      for message in request.initialMessages {
        try await append(.messageAppended(message), to: request.runID)
      }

      return try await execute(request, model: model)
    } catch is CancellationError {
      if didStart {
        try await finishNeverStartedToolCalls(for: request.runID, reason: .cancelled)
        try await appendTerminal(.runCancelled, to: request.runID)
      }
      throw CancellationError()
    } catch let error as AgentRuntimeError {
      if didStart {
        try await finishNeverStartedToolCalls(for: request.runID, reason: .runStopped)
        let isRetryable = !runsWithStartedTools.contains(request.runID)
        let constrainedError = error.constrainingRetryability(to: isRetryable)
        try await appendTerminal(
          .runFailed(constrainedError.agentFailure(isRetryable: isRetryable)),
          to: request.runID
        )
        throw constrainedError
      }
      throw error
    } catch {
      let error = AgentRuntimeError.invalidState("The runtime encountered an unexpected failure.")
      if didStart {
        try await finishNeverStartedToolCalls(for: request.runID, reason: .runStopped)
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
