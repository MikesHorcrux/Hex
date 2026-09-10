import HexCore

/// Plans context only at a fresh-inference/user-exchange boundary. It is intentionally independent
/// of providers, files, stores, and summarizers. Continuation-bound history is never compactable.
public struct AgentContextPlanner: Sendable {
  public let fallbackContextWindow: Int
  public let safetyMarginTokens: Int
  public let summaryReserveTokens: Int
  private let estimator: any AgentContextTokenEstimating

  public init(
    fallbackContextWindow: Int = 32_768,
    safetyMarginTokens: Int = 1_024,
    summaryReserveTokens: Int = 1_024,
    estimator: any AgentContextTokenEstimating = ConservativeAgentContextTokenEstimator()
  ) throws {
    guard fallbackContextWindow > 0, safetyMarginTokens >= 0, summaryReserveTokens > 0 else {
      throw AgentContextPlanningError.invalidConfiguration
    }
    self.fallbackContextWindow = fallbackContextWindow
    self.safetyMarginTokens = safetyMarginTokens
    self.summaryReserveTokens = summaryReserveTokens
    self.estimator = estimator
  }

  /// `outputReserveTokens` must be chosen from the actual request/provider configuration. The
  /// planner cannot infer an absent provider default; callers must not treat this as usage proof.
  public func plan(
    pinnedMessages: [Message],
    messages: [Message],
    tools: [ToolDefinition],
    model: ModelDescriptor,
    outputReserveTokens: Int,
    previousProviderResponseID: String? = nil,
    maximumPlanningWindowTokens: Int? = nil
  ) throws -> AgentContextPlan {
    guard model.contextWindow.map({ $0 > 0 }) ?? true,
      model.maxOutputTokens.map({ $0 > 0 }) ?? true
    else { throw AgentContextPlanningError.invalidModelMetadata }
    guard outputReserveTokens > 0 else { throw AgentContextPlanningError.invalidOutputReserve }
    guard maximumPlanningWindowTokens.map({ $0 > 0 }) ?? true else {
      throw AgentContextPlanningError.invalidConfiguration
    }
    let layout = try exchangeLayout(pinnedMessages: pinnedMessages, messages: messages)
    let estimator = ModelBoundAgentContextTokenEstimator(base: self.estimator, model: model)
    // A caller may plan against a smaller working budget, never enlarge the model's window.
    let window = min(
      model.contextWindow ?? fallbackContextWindow, maximumPlanningWindowTokens ?? Int.max)
    let pinnedTokens: Int
    let messageCosts: [Int]
    let toolTokens: Int
    do {
      pinnedTokens = try sum(
        pinnedMessages.map { try validatedEstimate(estimator.estimateTokens(in: $0)) })
      messageCosts = try messages.map { try validatedEstimate(estimator.estimateTokens(in: $0)) }
      toolTokens = try sum(tools.map { try validatedEstimate(estimator.estimateTokens(in: $0)) })
    } catch AgentContextPlanningError.imageCostUnavailable {
      return .unestimated(.imageCostUnavailable)
    }
    let historyTokens = try sum(messageCosts)
    let protectedHistoryTokens = try sum(messageCosts[layout.protectedStart...])
    let fixedTokens = try sum([pinnedTokens, toolTokens, outputReserveTokens, safetyMarginTokens])
    let total = try sum([fixedTokens, historyTokens])
    let protectedTotal = try sum([fixedTokens, protectedHistoryTokens])
    let budget = AgentContextBudget(
      contextWindowTokens: window,
      usesFallbackContextWindow: model.contextWindow == nil,
      pinnedTokens: pinnedTokens,
      historyTokens: historyTokens,
      protectedHistoryTokens: protectedHistoryTokens,
      toolSchemaTokens: toolTokens,
      outputReserveTokens: outputReserveTokens,
      safetyMarginTokens: safetyMarginTokens,
      estimatedTotalTokens: total,
      estimatedProtectedTotalTokens: protectedTotal
    )
    guard total > window else { return .fits(budget) }
    guard previousProviderResponseID == nil else {
      return .protectedOverflow(budget, reason: .activeProviderContinuation)
    }
    guard !layout.hasOpenToolChain else {
      return .protectedOverflow(budget, reason: .openToolChain)
    }
    guard try sum([protectedTotal, summaryReserveTokens]) <= window else {
      return .protectedOverflow(budget, reason: .protectedContext)
    }

    var removedTokens = 0
    for exchange in layout.closedExchanges where exchange.upperBound <= layout.protectedStart {
      removedTokens = try sum([removedTokens, try sum(messageCosts[exchange])])
      let retainedTokens = historyTokens - removedTokens
      if try sum([fixedTokens, retainedTokens, summaryReserveTokens]) <= window {
        return .requiresCompaction(
          budget,
          prefixRange: 0..<exchange.upperBound,
          retainedRange: exchange.upperBound..<messages.count,
          maximumSummaryTokens: summaryReserveTokens
        )
      }
    }
    return .protectedOverflow(budget, reason: .protectedContext)
  }

  private struct ExchangeLayout: Sendable {
    let closedExchanges: [Range<Int>]
    let protectedStart: Int
    let hasOpenToolChain: Bool
  }

  private func exchangeLayout(pinnedMessages: [Message], messages: [Message]) throws
    -> ExchangeLayout
  {
    var messageIDs = Set<MessageID>()
    for message in pinnedMessages {
      guard messageIDs.insert(message.id).inserted, !message.content.isEmpty else {
        throw AgentContextPlanningError.invalidHistory
      }
      for content in message.content {
        switch content {
        case .toolCall, .toolResult:
          // A call/result exchange may not straddle the pinned and compactable input partitions.
          throw AgentContextPlanningError.invalidHistory
        case .text, .image:
          break
        }
      }
    }
    guard messages.first?.role == .user else { throw AgentContextPlanningError.invalidHistory }
    var closed: [Range<Int>] = []
    var start = 0
    var latestUserIndex = 0
    var seenCalls = Set<ToolCallID>()
    var pendingCalls = Set<ToolCallID>()
    var hasOpenToolChain = false
    var endsWithFinalAssistant = false
    for (index, message) in messages.enumerated() {
      guard messageIDs.insert(message.id).inserted, !message.content.isEmpty else {
        throw AgentContextPlanningError.invalidHistory
      }
      switch message.role {
      case .system, .developer:
        // Instructions/summary context must be explicitly pinned by the owning trusted caller.
        throw AgentContextPlanningError.invalidHistory
      case .user:
        guard pendingCalls.isEmpty else { throw AgentContextPlanningError.invalidHistory }
        if index > start {
          // A new real user message ends the prior exchange even after a cancelled/failed attempt.
          // Closed here means its tool pairs are complete, not that its task succeeded.
          closed.append(start..<index)
          start = index
        }
        latestUserIndex = index
        hasOpenToolChain = false
        endsWithFinalAssistant = false
        try validateUserContent(message)
      case .assistant:
        guard pendingCalls.isEmpty else { throw AgentContextPlanningError.invalidHistory }
        var hasCalls = false
        for content in message.content {
          switch content {
          case .toolCall(let call):
            guard call.id.rawValue.contains(where: { !$0.isWhitespace }),
              call.name.contains(where: { !$0.isWhitespace }), seenCalls.insert(call.id).inserted
            else {
              throw AgentContextPlanningError.invalidHistory
            }
            pendingCalls.insert(call.id)
            hasCalls = true
          case .toolResult:
            throw AgentContextPlanningError.invalidHistory
          case .text, .image:
            break
          }
        }
        hasOpenToolChain = hasCalls
        endsWithFinalAssistant = !hasCalls
      case .tool:
        for content in message.content {
          guard case .toolResult(let result) = content,
            pendingCalls.remove(result.toolCallID) != nil
          else { throw AgentContextPlanningError.invalidHistory }
        }
        endsWithFinalAssistant = false
      }
    }
    if endsWithFinalAssistant && pendingCalls.isEmpty { closed.append(start..<messages.count) }
    let protectedStart = min(latestUserIndex, closed.last?.lowerBound ?? latestUserIndex)
    return ExchangeLayout(
      closedExchanges: closed,
      protectedStart: protectedStart,
      hasOpenToolChain: hasOpenToolChain || !pendingCalls.isEmpty
    )
  }

  private func validateUserContent(_ message: Message) throws {
    for content in message.content {
      switch content {
      case .toolCall, .toolResult:
        throw AgentContextPlanningError.invalidHistory
      case .text, .image:
        break
      }
    }
  }

  private func validatedEstimate(_ estimate: Int) throws -> Int {
    guard estimate >= 0 else { throw AgentContextPlanningError.invalidEstimate }
    return estimate
  }

  private func sum(_ values: some Sequence<Int>) throws -> Int {
    var total = 0
    for value in values {
      let (next, overflow) = total.addingReportingOverflow(value)
      guard !overflow else { throw AgentContextPlanningError.arithmeticOverflow }
      total = next
    }
    return total
  }
}
