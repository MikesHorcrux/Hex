import Foundation
import HexCore

extension AgentRuntime {
  /// This runs once, before any primary inference or tool execution. Originals have already been
  /// journaled. Only a validated and durably appended compaction may change the effective context.
  func prepareInitialContext(
    _ request: AgentRunRequest, model: ModelDescriptor, tools: [ToolDefinition]
  )
    async throws -> (messages: [Message], reportedTokens: UInt64)
  {
    let artifactContext = runArtifactContextMessages[request.runID].map { [$0] } ?? []
    let original = request.contextMessages + artifactContext + request.initialMessages
    guard configuration.context.isEnabled else { return (original, 0) }
    let reserve = outputReservation(request, model: model)
    // Trusted gateway context and any explicit leading instruction messages are never summarized.
    let instructionPrefix = request.initialMessages.prefix {
      $0.role == .system || $0.role == .developer
    }
    let pinned = request.contextMessages + artifactContext + instructionPrefix
    let history = Array(request.initialMessages.dropFirst(instructionPrefix.count))
    let window = model.contextWindow ?? configuration.context.fallbackContextWindow
    // Retain a useful checkpoint on large models without reserving most of a small model's input.
    // These are local estimator units, not an assertion about the provider's exact tokenizer.
    let summaryLimit = min(
      configuration.context.maximumSummaryTokens,
      max(1, window / 8), model.maxOutputTokens ?? Int.max)
    // Reserve the immutable provenance label and normal serialized Message framing as well as text.
    let planner = try makeContextPlanner(summaryReserve: summaryLimit + 256)
    let plan: AgentContextPlan
    do {
      plan = try planner.plan(
        pinnedMessages: pinned, messages: history, tools: tools,
        model: model, outputReserveTokens: reserve)
    } catch AgentContextPlanningError.invalidHistory {
      // Some programmatic callers provide a continuation-shaped initial history. It can be used
      // unchanged when it fits, but we never invent a user boundary to make it compactable.
      try validateContinuingContext(original, request: request, model: model, tools: tools)
      return (original, 0)
    } catch {
      throw AgentRuntimeError.invalidRequest(
        "The conversation context could not be planned safely.")
    }
    switch plan {
    case .fits, .unestimated:
      // No tokenizer/image-cost evidence is invented. Unestimated multimodal requests retain their
      // existing provider validation; model-specific image estimators can be injected at this seam.
      return (original, 0)
    case .protectedOverflow:
      throw contextOverflow()
    case .requiresCompaction(let before, let prefix, let retained, _):
      try Task.checkCancellation()
      try await append(.contextCompactionStarted, to: request.runID)
      let summary: AgentContextSummaryResult
      do {
        summary = try await contextSummarizer.summarize(
          AgentContextSummaryRequest(
            model: model, sourceMessages: Array(history[prefix]),
            maximumSummaryTokens: summaryLimit,
            maximumReportedTokens: configuration.budget.maxReportedTokens))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if Task.isCancelled { throw CancellationError() }
        throw AgentRuntimeError.providerFailure(
          "Hex could not condense the earlier conversation. Original messages are preserved; retry or start a new conversation.",
          isRetryable: true)
      }
      try Task.checkCancellation()
      guard summary.inferenceCalls > 0,
        summary.inferenceCalls <= configuration.context.maximumSummaryCalls,
        summary.reportedTokens <= configuration.budget.maxReportedTokens
      else {
        throw AgentRuntimeError.protocolViolation("The context summary exceeded its work budget.")
      }
      let provisional: AgentContextCompaction
      do {
        provisional = try AgentContextCompaction(
          ownerRunID: request.runID,
          sourceMessageIDs: history[prefix].map(\.id), summaryText: summary.text,
          providerID: inferenceProvider.descriptor.id, modelID: request.modelID,
          estimatedTokensBefore: before.estimatedTotalTokens, estimatedTokensAfter: 1)
      } catch {
        throw AgentRuntimeError.protocolViolation("The context summary was empty or invalid.")
      }
      let compactedHistory = [provisional.summaryMessage] + history[retained]
      let after: AgentContextBudget
      do {
        guard
          case .fits(let budget) = try planner.plan(
            pinnedMessages: pinned,
            messages: compactedHistory, tools: tools, model: model, outputReserveTokens: reserve)
        else { throw contextOverflow() }
        after = budget
      } catch {
        throw AgentRuntimeError.budgetExceeded(
          "The summarized conversation still does not fit this model. Original messages are preserved; choose a larger-context model or start a new conversation."
        )
      }
      guard
        try contextEstimator.estimateTokens(in: provisional.summaryMessage) <= summaryLimit + 256
      else {
        throw AgentRuntimeError.protocolViolation("The context summary exceeded its reserved size.")
      }
      let committed = try AgentContextCompaction(
        id: provisional.id, ownerRunID: request.runID,
        sourceMessageIDs: provisional.sourceMessageIDs, summaryText: summary.text,
        providerID: provisional.providerID, modelID: provisional.modelID,
        estimatedTokensBefore: before.estimatedTotalTokens,
        estimatedTokensAfter: after.estimatedTotalTokens,
        reportedTokens: summary.reportedTokens, inferenceCalls: summary.inferenceCalls)
      let candidate = pinned + compactedHistory
      try validateConversationSize(candidate)
      // Journal rejection/cancellation prevents primary inference from observing the replacement.
      try await append(.contextCompacted(committed), to: request.runID)
      try Task.checkCancellation()
      return (candidate, summary.reportedTokens)
    }
  }

  /// Never rewrite an active provider continuation (including local opaque reasoning replay).
  /// Oversized tool loops stop with an explicit outcome rather than silently losing their history.
  func validateContinuingContext(
    _ messages: [Message], request: AgentRunRequest,
    model: ModelDescriptor, tools: [ToolDefinition]
  ) throws {
    guard configuration.context.isEnabled else { return }
    var total = outputReservation(request, model: model)
    let costs: [Int]
    do {
      costs =
        try messages.map { try contextEstimator.estimateTokens(in: $0) }
        + tools.map { try contextEstimator.estimateTokens(in: $0) }
        + [configuration.context.safetyMarginTokens]
    } catch AgentContextPlanningError.imageCostUnavailable { return } catch {
      throw AgentRuntimeError.invalidRequest("Context cost could not be estimated.")
    }
    for cost in costs {
      let (next, overflow) = total.addingReportingOverflow(cost)
      guard cost >= 0, !overflow else { throw contextOverflow() }
      total = next
    }
    guard total <= (model.contextWindow ?? configuration.context.fallbackContextWindow) else {
      throw contextOverflow()
    }
  }

  private func outputReservation(_ request: AgentRunRequest, model: ModelDescriptor) -> Int {
    if let requested = request.options.maxOutputTokens { return requested }
    if let modelMaximum = model.maxOutputTokens { return modelMaximum }
    // An explicit local planning allowance when metadata is unavailable, NOT a claimed provider
    // default or server-enforced limit. Ordinary request options are not silently rewritten.
    let window = model.contextWindow ?? configuration.context.fallbackContextWindow
    return min(configuration.context.fallbackOutputReserveTokens, max(1, window / 4))
  }

  private func makeContextPlanner(summaryReserve: Int) throws -> AgentContextPlanner {
    try AgentContextPlanner(
      fallbackContextWindow: configuration.context.fallbackContextWindow,
      safetyMarginTokens: configuration.context.safetyMarginTokens,
      summaryReserveTokens: summaryReserve, estimator: contextEstimator)
  }

  private func contextOverflow() -> AgentRuntimeError {
    .budgetExceeded(
      "The current request, required instructions, tools, or active tool exchange exceed this model's estimated context. Hex will not trim them silently. Choose a larger-context model, reduce enabled tools, or start a new conversation for a shorter task."
    )
  }
}
