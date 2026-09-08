import Foundation
import HexCore

extension AgentRuntime {
  /// Only called after every announced tool has a durable result. Preserve the admitted initial
  /// task and trusted context verbatim; replace generated, fully paired evidence as historical data.
  /// A nil continuation ID on the next request starts a supported fresh provider replay boundary.
  func prepareActiveContext(
    _ messages: [Message], protectedCount: Int, request: AgentRunRequest,
    model: ModelDescriptor, tools: [ToolDefinition], remainingReportedTokens: UInt64
  ) async throws -> (messages: [Message], reportedTokens: UInt64)? {
    guard configuration.context.isEnabled else { return nil }
    let before = try activeContextCost(messages, request: request, model: model, tools: tools)
    let window = model.contextWindow ?? configuration.context.fallbackContextWindow
    guard before > window else { return nil }
    guard protectedCount > 0, messages.count > protectedCount else { throw contextOverflow() }
    let pinned = Array(messages.prefix(protectedCount))
    let source = Array(messages.dropFirst(protectedCount))
    let currentTask = request.initialMessages.last { $0.role == .user }
    guard source.last?.role == .tool else { throw contextOverflow() }
    // The same strict source validator used by the real summarizer guards injected implementations.
    _ = try AgentContextSummarySource(
      messages: source,
      estimator: ModelBoundAgentContextTokenEstimator(base: contextEstimator, model: model),
      allowsToolBatchBoundaries: true)
    let limit = min(
      configuration.context.maximumSummaryTokens, max(1, window / 8),
      model.maxOutputTokens ?? Int.max)
    let fixed = try activeContextCost(pinned, request: request, model: model, tools: tools)
    guard fixed < window, limit + 256 <= window - fixed else { throw contextOverflow() }
    try Task.checkCancellation()
    try await append(.contextCompactionStarted, to: request.runID)
    let summary: AgentContextSummaryResult
    do {
      summary = try await contextSummarizer.summarize(
        AgentContextSummaryRequest(
          model: model, sourceMessages: source, maximumSummaryTokens: limit,
          maximumReportedTokens: remainingReportedTokens, allowsToolBatchBoundaries: true,
          currentTask: currentTask))
    } catch is CancellationError { throw CancellationError() } catch {
      if Task.isCancelled { throw CancellationError() }
      throw AgentRuntimeError.providerFailure(
        "Hex could not condense the completed tool work. Original evidence is preserved; retry or use a larger-context model.",
        isRetryable: true)
    }
    try Task.checkCancellation()
    guard summary.inferenceCalls > 0,
      summary.inferenceCalls <= configuration.context.maximumSummaryCalls,
      summary.reportedTokens <= remainingReportedTokens
    else {
      throw AgentRuntimeError.protocolViolation("The context summary exceeded its work budget.")
    }
    let provisional = try AgentContextCompaction(
      ownerRunID: request.runID, sourceMessageIDs: source.map(\.id), summaryText: summary.text,
      providerID: inferenceProvider.descriptor.id, modelID: request.modelID,
      estimatedTokensBefore: before, estimatedTokensAfter: 1,
      reportedTokens: summary.reportedTokens, inferenceCalls: summary.inferenceCalls,
      boundary: .completedToolBatch, taskMessageID: currentTask?.id)
    guard
      try contextEstimator.estimateTokens(in: provisional.summaryMessage, model: model) <= limit
        + 256
    else {
      throw AgentRuntimeError.protocolViolation("The context summary exceeded its reserved size.")
    }
    let candidate = pinned + [provisional.summaryMessage]
    try validateConversationSize(candidate)
    try validateContinuingContext(candidate, request: request, model: model, tools: tools)
    let record = try AgentContextCompaction(
      id: provisional.id, ownerRunID: request.runID, sourceMessageIDs: source.map(\.id),
      summaryText: summary.text, providerID: provisional.providerID, modelID: request.modelID,
      estimatedTokensBefore: before,
      estimatedTokensAfter: activeContextCost(
        candidate, request: request, model: model, tools: tools),
      reportedTokens: summary.reportedTokens, inferenceCalls: summary.inferenceCalls,
      boundary: .completedToolBatch, taskMessageID: currentTask?.id)
    try await append(.contextCompacted(record), to: request.runID)
    try Task.checkCancellation()
    return (candidate, summary.reportedTokens)
  }

  private func activeContextCost(
    _ messages: [Message], request: AgentRunRequest, model: ModelDescriptor, tools: [ToolDefinition]
  ) throws -> Int {
    var total = outputReservation(request, model: model)
    let costs: [Int]
    do {
      costs =
        try messages.map { try contextEstimator.estimateTokens(in: $0, model: model) }
        + tools.map { try contextEstimator.estimateTokens(in: $0, model: model) }
        + [configuration.context.safetyMarginTokens]
    } catch AgentContextPlanningError.imageCostUnavailable {
      throw unknownContextCost()
    }
    for cost in costs {
      let (next, overflow) = total.addingReportingOverflow(cost)
      guard cost >= 0, !overflow else { throw contextOverflow() }
      total = next
    }
    return total
  }
}
