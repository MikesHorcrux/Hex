import Foundation
import HexCore
import Testing

@testable import HexRuntime

@Suite("Agent context planning")
struct AgentContextPlannerTests {
  @Test
  func explicitRecoveryCanCondenseThePreviousWholeExchangeAfterANewUserBoundary() throws {
    let call = ToolCall(name: "probe", arguments: [:])
    let history = [
      user("Original task"), Message(role: .assistant, content: [.toolCall(call)]),
      result(call), user("Continue with this correction"),
    ]
    let planner = try makePlanner()
    let ordinary = try planner.plan(
      pinnedMessages: [], messages: history, tools: [], model: model(window: 50),
      outputReserveTokens: 20)
    guard case .protectedOverflow(_, .protectedContext) = ordinary else {
      Issue.record("The default preference should retain the latest prior exchange")
      return
    }
    let recovery = try planner.plan(
      pinnedMessages: [], messages: history, tools: [], model: model(window: 50),
      outputReserveTokens: 20, allowLatestClosedExchangeCompaction: true)
    guard case .requiresCompaction(let budget, let prefix, let retained, _) = recovery else {
      Issue.record("Expected the prior exchange, including both tool halves, to be eligible")
      return
    }
    #expect(prefix == 0..<3)
    #expect(retained == 3..<4)
    #expect(budget.protectedHistoryTokens == 10)
  }

  @Test
  func recoveryNeverCondensesTheCurrentExchangeOrAProviderContinuation() throws {
    let planner = try makePlanner()
    let history = [user("Before"), assistant("Done"), user("Current request")]
    let tooSmall = try planner.plan(
      pinnedMessages: [], messages: history, tools: [], model: model(window: 45),
      outputReserveTokens: 20, allowLatestClosedExchangeCompaction: true)
    guard case .protectedOverflow(_, .protectedContext) = tooSmall else {
      Issue.record("Current request plus required reserves must remain protected")
      return
    }
    let continuation = try planner.plan(
      pinnedMessages: [], messages: history, tools: [], model: model(window: 50),
      outputReserveTokens: 20, previousProviderResponseID: "active",
      allowLatestClosedExchangeCompaction: true)
    guard case .protectedOverflow(_, .activeProviderContinuation) = continuation else {
      Issue.record("Recovery must not rewrite a provider continuation")
      return
    }
    let call = ToolCall(name: "probe", arguments: [:])
    let active = try planner.plan(
      pinnedMessages: [],
      messages: history + [Message(role: .assistant, content: [.toolCall(call)]), result(call)],
      tools: [], model: model(window: 60), outputReserveTokens: 20,
      allowLatestClosedExchangeCompaction: true)
    guard case .protectedOverflow(_, .openToolChain) = active else {
      Issue.record("Current tool work must not be condensed by initial admission")
      return
    }
  }

  @Test
  func workingWindowCannotEnlargeTheModelOrWeakenProtectedHistory() throws {
    let history = [user("old"), assistant("old"), user("recent"), assistant("recent"), user("now")]
    let planner = try makePlanner()
    let enlarged = try planner.plan(
      pinnedMessages: [], messages: history, tools: [], model: model(window: 70),
      outputReserveTokens: 20, maximumPlanningWindowTokens: 1_000)
    guard case .requiresCompaction(let budget, _, _, _) = enlarged else {
      Issue.record("A requested planning cap must not enlarge the provider window")
      return
    }
    #expect(budget.contextWindowTokens == 70)
    let reduced = try planner.plan(
      pinnedMessages: [], messages: history, tools: [], model: model(window: 70),
      outputReserveTokens: 20, maximumPlanningWindowTokens: 50)
    guard case .protectedOverflow(_, reason: .protectedContext) = reduced else {
      Issue.record("A smaller planning window must still preserve protected history")
      return
    }
    #expect(throws: AgentContextPlanningError.invalidConfiguration) {
      _ = try planner.plan(
        pinnedMessages: [], messages: history, tools: [], model: model(window: 70),
        outputReserveTokens: 20, maximumPlanningWindowTokens: 0)
    }
  }

  @Test
  func accountsForPinnedHistoryToolsOutputAndMarginWithoutChangingMessages() throws {
    let planner = try makePlanner()
    let history = [user("old"), assistant("reply"), user("latest")]
    let plan = try planner.plan(
      pinnedMessages: [Message(role: .developer, content: [.text("policy")])],
      messages: history,
      tools: [tool],
      model: model(window: 100),
      outputReserveTokens: 20
    )
    guard case .fits(let budget) = plan else {
      Issue.record("Expected the entire unmodified history to fit")
      return
    }
    #expect(budget.pinnedTokens == 10)
    #expect(budget.historyTokens == 30)
    #expect(budget.toolSchemaTokens == 20)
    #expect(budget.outputReserveTokens == 20)
    #expect(budget.safetyMarginTokens == 10)
    #expect(budget.estimatedTotalTokens == 90)
    #expect(budget.protectedHistoryTokens == 30)
    #expect(!budget.usesFallbackContextWindow)
    #expect(history.count == 3)
  }

  @Test
  func reportsTheExplicitFallbackWindowAsEstimated() throws {
    let plan = try makePlanner(fallback: 77).plan(
      pinnedMessages: [], messages: [user("latest")], tools: [],
      model: model(window: nil), outputReserveTokens: 20
    )
    guard case .fits(let budget) = plan else {
      Issue.record("Expected fallback accounting")
      return
    }
    #expect(budget.contextWindowTokens == 77)
    #expect(budget.usesFallbackContextWindow)
  }

  @Test
  func proposesOnlyAnOldClosedPrefixRetainingLastExchangeAndLatestUser() throws {
    let history = [
      user("old"), assistant("old answer"), user("recent"),
      assistant("recent answer"), user("latest request"),
    ]
    let plan = try makePlanner().plan(
      pinnedMessages: [], messages: history, tools: [], model: model(window: 70),
      outputReserveTokens: 20
    )
    guard case .requiresCompaction(let budget, let prefix, let retained, let summaryBudget) = plan
    else {
      Issue.record("Expected an explicit compaction proposal, not truncated messages")
      return
    }
    #expect(budget.estimatedTotalTokens == 80)
    #expect(prefix == 0..<2)
    #expect(retained == 2..<5)
    #expect(summaryBudget == 10)
    #expect(history[retained].map(\.id) == Array(history.suffix(3)).map(\.id))
  }

  @Test
  func keepsParallelToolCallsAndEveryResultInTheSameClosedExchange() throws {
    let first = ToolCall(id: ToolCallID(rawValue: "first"), name: "probe", arguments: [:])
    let second = ToolCall(id: ToolCallID(rawValue: "second"), name: "probe", arguments: [:])
    let history = [
      user("old"),
      Message(role: .assistant, content: [.toolCall(first), .toolCall(second)]),
      result(second), result(first), assistant("finished old"),
      user("recent"), assistant("finished recent"), user("latest"),
    ]
    let plan = try makePlanner().plan(
      pinnedMessages: [], messages: history, tools: [], model: model(window: 70),
      outputReserveTokens: 20
    )
    guard case .requiresCompaction(_, let prefix, let retained, _) = plan else {
      Issue.record("Expected a whole closed tool exchange")
      return
    }
    #expect(prefix == 0..<5)
    #expect(retained == 5..<8)
  }

  @Test
  func neverRewritesAnActiveProviderContinuation() throws {
    let plan = try makePlanner().plan(
      pinnedMessages: [],
      messages: [user("old"), assistant("old answer"), user("latest")],
      tools: [], model: model(window: 45), outputReserveTokens: 20,
      previousProviderResponseID: "single-use-response"
    )
    guard case .protectedOverflow(_, .activeProviderContinuation) = plan else {
      Issue.record("Active continuation history must remain untouched")
      return
    }
  }

  @Test
  func refusesCompactionInsideAnOpenToolChainEvenWithoutProviderResponseID() throws {
    let call = ToolCall(name: "probe", arguments: [:])
    let history = [
      user("old"), assistant("old answer"), user("latest"),
      Message(role: .assistant, content: [.toolCall(call)]), result(call),
    ]
    let plan = try makePlanner().plan(
      pinnedMessages: [], messages: history, tools: [], model: model(window: 60),
      outputReserveTokens: 20
    )
    guard case .protectedOverflow(_, .openToolChain) = plan else {
      Issue.record("Resolved tool results still await the current exchange's final assistant reply")
      return
    }
  }

  @Test
  func returnsProtectedOverflowRatherThanDroppingPinnedOrMostRecentExchange() throws {
    let plan = try makePlanner().plan(
      pinnedMessages: [Message(role: .developer, content: [.text("must keep")])],
      messages: [
        user("old"), assistant("old answer"), user("recent"),
        assistant("recent answer"), user("latest"),
      ],
      tools: [tool], model: model(window: 80), outputReserveTokens: 20
    )
    guard case .protectedOverflow(let budget, .protectedContext) = plan else {
      Issue.record("Protected content plus summary reserve cannot fit")
      return
    }
    #expect(budget.protectedHistoryTokens == 30)
  }

  @Test
  func rejectsOrphanResultsAndDuplicateCallIdentities() throws {
    let call = ToolCall(id: ToolCallID(rawValue: "duplicate"), name: "probe", arguments: [:])
    let planner = try makePlanner()
    #expect(throws: AgentContextPlanningError.invalidHistory) {
      try planner.plan(
        pinnedMessages: [], messages: [user("hello"), result(call)], tools: [],
        model: model(window: 100), outputReserveTokens: 20
      )
    }
    #expect(throws: AgentContextPlanningError.invalidHistory) {
      try planner.plan(
        pinnedMessages: [],
        messages: [
          user("hello"),
          Message(role: .assistant, content: [.toolCall(call), .toolCall(call)]),
        ], tools: [],
        model: model(window: 100), outputReserveTokens: 20
      )
    }
  }

  @Test
  func unknownImageCostsAreExplicitlyUnestimatedNotAssumedToBeURLText() throws {
    let planner = try AgentContextPlanner()
    let image = try #require(URL(string: "https://example.test/image.png"))
    let plan = try planner.plan(
      pinnedMessages: [],
      messages: [
        Message(
          role: .user, content: [.image(ImageContent(sourceURL: image, mediaType: "image/png"))])
      ],
      tools: [], model: model(window: 32_768), outputReserveTokens: 1_024
    )
    #expect(plan == .unestimated(.imageCostUnavailable))
  }

  @Test
  func completedBoundaryRetainsTheNewestClosedExchangeWithoutRequiringAnExtraOldOne() throws {
    let history = [user("old"), assistant("old reply"), user("recent"), assistant("recent reply")]
    let plan = try makePlanner().plan(
      pinnedMessages: [], messages: history, tools: [], model: model(window: 60),
      outputReserveTokens: 20
    )
    guard case .requiresCompaction(_, let prefix, let retained, _) = plan else {
      Issue.record("Expected the most recent complete exchange to remain verbatim")
      return
    }
    #expect(prefix == 0..<2)
    #expect(retained == 2..<4)
  }

  @Test
  func aNewUserBoundaryCanCloseAResolvedButInterruptedToolAttempt() throws {
    let call = ToolCall(name: "probe", arguments: [:])
    let history = [
      user("interrupted"), Message(role: .assistant, content: [.toolCall(call)]),
      result(call), user("recent"), assistant("recent reply"), user("latest"),
    ]
    let plan = try makePlanner().plan(
      pinnedMessages: [], messages: history, tools: [], model: model(window: 70),
      outputReserveTokens: 20
    )
    guard case .requiresCompaction(_, let prefix, let retained, _) = plan else {
      Issue.record(
        "Closed means complete tool pairs, not a false claim that the prior task succeeded")
      return
    }
    #expect(prefix == 0..<3)
    #expect(retained == 3..<6)
  }

  @Test
  func injectableImageCostCanPlanWithoutOpeningOrFetchingTheImage() throws {
    let image = try #require(URL(string: "https://example.test/not-fetched.png"))
    let plan = try makePlanner().plan(
      pinnedMessages: [],
      messages: [
        Message(
          role: .user, content: [.image(ImageContent(sourceURL: image, mediaType: "image/png"))])
      ],
      tools: [], model: model(window: 100), outputReserveTokens: 20
    )
    guard case .fits(let budget) = plan else {
      Issue.record("An explicitly injected image estimator can supply a cost")
      return
    }
    #expect(budget.historyTokens == 10)
  }

  @Test
  func invalidKnownWindowDoesNotFallBackAndInvalidConfigurationIsRejected() throws {
    #expect(throws: AgentContextPlanningError.invalidConfiguration) {
      try AgentContextPlanner(fallbackContextWindow: 0)
    }
    #expect(throws: AgentContextPlanningError.invalidConfiguration) {
      try AgentContextPlanner(safetyMarginTokens: -1)
    }
    let planner = try makePlanner()
    #expect(throws: AgentContextPlanningError.invalidModelMetadata) {
      try planner.plan(
        pinnedMessages: [], messages: [user("latest")], tools: [], model: model(window: 0),
        outputReserveTokens: 20
      )
    }
    #expect(throws: AgentContextPlanningError.invalidOutputReserve) {
      try planner.plan(
        pinnedMessages: [], messages: [user("latest")], tools: [], model: model(window: 100),
        outputReserveTokens: 0
      )
    }
  }

  @Test
  func rejectsNegativeEstimatesAndArithmeticOverflowWithoutCrashing() throws {
    let history = [user("latest")]
    let cases: [(Int, AgentContextPlanningError)] = [
      (-1, .invalidEstimate), (Int.max, .arithmeticOverflow),
    ]
    for (tokens, error) in cases {
      let planner = try AgentContextPlanner(estimator: FixedEstimator(messageTokens: tokens))
      #expect(throws: error) {
        try planner.plan(
          pinnedMessages: [], messages: history, tools: [], model: model(window: 100),
          outputReserveTokens: 20
        )
      }
    }
  }

  private func makePlanner(fallback: Int = 100) throws -> AgentContextPlanner {
    try AgentContextPlanner(
      fallbackContextWindow: fallback, safetyMarginTokens: 10, summaryReserveTokens: 10,
      estimator: FixedEstimator(messageTokens: 10)
    )
  }

  private func model(window: Int?) -> ModelDescriptor {
    ModelDescriptor(
      id: ModelID(rawValue: "test"), providerID: ProviderID(rawValue: "test"),
      displayName: "Test", capabilities: [.textInput, .toolCalling], contextWindow: window
    )
  }

  private func user(_ text: String) -> Message { Message(role: .user, content: [.text(text)]) }
  private func assistant(_ text: String) -> Message {
    Message(role: .assistant, content: [.text(text)])
  }
  private func result(_ call: ToolCall) -> Message {
    Message(
      role: .tool,
      content: [
        .toolResult(ToolResult(toolCallID: call.id, status: .success, output: .string("done")))
      ])
  }

  private var tool: ToolDefinition {
    ToolDefinition(name: "probe", description: "Test", inputSchema: ["type": .string("object")])
  }

  private struct FixedEstimator: AgentContextTokenEstimating {
    let messageTokens: Int
    func estimateTokens(in message: Message) throws -> Int { messageTokens }
    func estimateTokens(in tool: ToolDefinition) throws -> Int { 20 }
  }
}
