import Foundation
import HexCore

extension InferenceAgentContextSummarizer {
  func infer(
    messages: [Message], request: AgentContextSummaryRequest, remainingReportedTokens: UInt64
  ) async throws -> AgentContextSummaryResult {
    try Task.checkCancellation()
    guard remainingReportedTokens > 0 else {
      throw AgentContextSummarizationError.reportedTokenBudgetExceeded
    }
    let budget = try AgentRunBudget(
      maxTextBytesPerTurn: min(262_144, request.maximumSummaryTokens * 8),
      maxSerializedOutputBytesPerTurn: 524_288)
    let supportsServerLimit =
      (provider as? any InferenceOutputLimitReporting)?.supportsServerOutputTokenLimit ?? true
    let inference = InferenceRequest(
      providerID: request.model.providerID, modelID: request.model.id,
      previousProviderResponseID: nil, messages: messages, tools: [], toolChoice: .none,
      // This is the summarizer's own local target, not an explicit ordinary user request. The
      // eager output check below applies even when the route cannot accept a server-side cap.
      options: InferenceOptions(
        maxOutputTokens: supportsServerLimit ? request.maximumSummaryTokens : nil,
        reasoningEffort: summaryReasoningEffort(for: request.model)))
    let stream: InferenceStream
    do { stream = try await provider.stream(inference) } catch is CancellationError {
      throw CancellationError()
    } catch {
      try Task.checkCancellation()
      throw AgentContextSummarizationError.providerFailed
    }
    let initial = InferenceTurnAccumulator(
      budget: budget, allowedToolNames: [], priorToolCallIDs: [], remainingToolCalls: 0,
      remainingReportedTokens: remainingReportedTokens, allowsParallelToolCalls: false)
    let summary = try await stream.consume { cursor in
      var accumulator = initial
      var summaryText = ""
      while true {
        try Task.checkCancellation()
        let event: InferenceStreamEvent?
        do { event = try await cursor.next() } catch is CancellationError {
          throw CancellationError()
        } catch {
          try Task.checkCancellation()
          throw AgentContextSummarizationError.providerFailed
        }
        guard let event else { break }
        if case .textDelta(let text) = event {
          let (bytes, overflow) = summaryText.utf8.count.addingReportingOverflow(text.utf8.count)
          guard !overflow, bytes <= budget.maxTextBytesPerTurn else {
            throw AgentContextSummarizationError.invalidSummary
          }
          summaryText.append(text)
          guard
            try estimatedInputTokens([Message(role: .user, content: [.text(summaryText)])])
              <= request.maximumSummaryTokens
          else { throw AgentContextSummarizationError.invalidSummary }
        }
        if case .usage(let usage) = event {
          let (total, overflow) = usage.inputTokens.addingReportingOverflow(usage.outputTokens)
          guard !overflow, total <= remainingReportedTokens else {
            throw AgentContextSummarizationError.reportedTokenBudgetExceeded
          }
          // Reported output includes hidden reasoning, whereas the local checkpoint budget
          // measures text retained in context. Only enforce a generation cap actually requested.
          if let outputLimit = inference.options.maxOutputTokens,
            usage.outputTokens > UInt64(outputLimit)
          {
            throw AgentContextSummarizationError.invalidStream
          }
        }
        do { try accumulator.accept(event) } catch {
          throw AgentContextSummarizationError.invalidStream
        }
      }
      try Task.checkCancellation()
      do {
        let output = try accumulator.finish()
        guard output.stopReason == .stop, output.toolCalls.isEmpty else {
          throw AgentContextSummarizationError.invalidStream
        }
        let text = output.assistantMessage.content.compactMap { content -> String? in
          if case .text(let value) = content { return value }
          return nil
        }.joined()
        return AgentContextSummaryResult(
          text: text, reportedTokens: output.reportedTokens,
          inferenceCalls: 1)
      } catch {
        throw AgentContextSummarizationError.invalidStream
      }
    }
    try Task.checkCancellation()
    let text = summary.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !text.contains("\0"),
      try estimatedInputTokens([Message(role: .user, content: [.text(text)])])
        <= request.maximumSummaryTokens
    else { throw AgentContextSummarizationError.invalidSummary }
    return AgentContextSummaryResult(
      text: text, reportedTokens: summary.reportedTokens,
      inferenceCalls: 1)
  }

  private func summaryReasoningEffort(for model: ModelDescriptor) -> InferenceReasoningEffort? {
    guard let supported = model.supportedReasoningEfforts, !supported.isEmpty else { return nil }
    // Prefer low for checkpoint fidelity even if a route also permits no reasoning. Otherwise
    // choose its lowest advertised effort; never infer support from a different provider route.
    if supported.contains(.low) { return .low }
    return InferenceReasoningEffort.allCases.first(where: supported.contains)
  }
}
