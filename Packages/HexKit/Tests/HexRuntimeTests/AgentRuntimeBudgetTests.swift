import Foundation
import HexCore
import Testing
@testable import HexRuntime

@Suite("AgentRuntime budgets")
struct AgentRuntimeBudgetTests {
  @Test
  func budgetRequiresPositiveBoundedValues() {
    #expect(throws: AgentRuntimeError.self) { try AgentRunBudget(maxTurns: 0) }
    #expect(throws: AgentRuntimeError.self) { try AgentRunBudget(maxToolCalls: 0) }
    #expect(throws: AgentRuntimeError.self) { try AgentRunBudget(maxDiscoveredTools: 0) }
    #expect(throws: AgentRuntimeError.self) {
      try AgentRunBudget(maxProviderEventsPerTurn: 0)
    }
    #expect(throws: AgentRuntimeError.self) { try AgentRunBudget(maxTextBytesPerTurn: 0) }
    #expect(throws: AgentRuntimeError.self) { try AgentRunBudget(maxInitialInputBytes: 0) }
    #expect(throws: AgentRuntimeError.self) { try AgentRunBudget(maxConversationBytes: 0) }
    #expect(throws: AgentRuntimeError.self) {
      try AgentRunBudget(maxSerializedOutputBytesPerTurn: 0)
    }
    #expect(throws: AgentRuntimeError.self) { try AgentRunBudget(maxReportedTokens: 0) }
    #expect(throws: AgentRuntimeError.self) {
      try AgentRunBudget(maxSerializedToolDefinitionsBytes: 0)
    }
    #expect(throws: AgentRuntimeError.self) { try AgentRunBudget(maxToolResultBytes: 0) }
    #expect(throws: AgentRuntimeError.self) { try AgentRunBudget(maxTotalToolResultBytes: 0) }
    #expect(throws: AgentRuntimeError.self) { try AgentRunBudget(maxJournalEventBytes: 0) }
    #expect(throws: AgentRuntimeError.self) { try AgentRunBudget(maxTurns: 257) }
  }

  @Test
  func budgetRejectsInternallyImpossibleCrossFieldLimits() {
    #expect(throws: AgentRuntimeError.self) {
      try AgentRunBudget(maxInitialInputBytes: 2, maxConversationBytes: 1)
    }
    #expect(throws: AgentRuntimeError.self) {
      try AgentRunBudget(maxToolResultBytes: 2, maxTotalToolResultBytes: 1)
    }
    #expect(throws: AgentRuntimeError.self) {
      try AgentRunBudget(
        maxTextBytesPerTurn: 2,
        maxSerializedOutputBytesPerTurn: 1
      )
    }
    #expect(throws: AgentRuntimeError.self) {
      try AgentRunBudget(
        maxConversationBytes: 4_194_304,
        maxSerializedToolDefinitionsBytes: 3_145_728
      )
    }
    #expect(throws: AgentRuntimeError.self) {
      try AgentRunBudget(maxToolResultBytes: 7_300_000)
    }
  }

  @Test
  func standardArtifactsFitDurableJournalEnvelopeWithHeadroom() throws {
    let budget = AgentRunBudget.standard
    let journalEnvelopeBytes = 8_388_608
    let requiredHeadroomBytes = 1_048_576
    #expect(budget.maxJournalEventBytes <= journalEnvelopeBytes - requiredHeadroomBytes)
    #expect(
      budget.maxConversationBytes + budget.maxSerializedToolDefinitionsBytes
        < budget.maxJournalEventBytes
    )
    #expect(budget.maxToolResultBytes < budget.maxJournalEventBytes)

    let messages = [
      Message(
        role: .user,
        content: [
          .text(String(repeating: "m", count: budget.maxConversationBytes - 4_096))
        ]
      )
    ]
    let tools = [
      ToolDefinition(
        name: "near-limit",
        description: String(
          repeating: "t",
          count: budget.maxSerializedToolDefinitionsBytes - 4_096
        ),
        inputSchema: ["type": .string("object")]
      )
    ]
    let request = InferenceRequest(
      providerID: RuntimeTestFixture.providerID,
      modelID: RuntimeTestFixture.modelID,
      messages: messages,
      tools: tools
    )
    let encodedMessages = try JSONEncoder().encode(messages)
    let encodedTools = try JSONEncoder().encode(tools)
    let encodedEvent = try JSONEncoder().encode(AgentEvent.inferenceRequested(request))
    let nearLimitResult = ToolResult(
      toolCallID: ToolCallID(rawValue: "near-limit-result"),
      status: .success,
      output: .string(
        String(repeating: "r", count: budget.maxToolResultBytes - 4_096)
      )
    )
    let encodedResult = try JSONEncoder().encode(nearLimitResult)
    let encodedResultEvent = try JSONEncoder().encode(AgentEvent.toolFinished(nearLimitResult))

    #expect(encodedMessages.count <= budget.maxConversationBytes)
    #expect(encodedTools.count <= budget.maxSerializedToolDefinitionsBytes)
    #expect(encodedEvent.count <= budget.maxJournalEventBytes)
    #expect(encodedEvent.count <= journalEnvelopeBytes - requiredHeadroomBytes)
    #expect(encodedResult.count <= budget.maxToolResultBytes)
    #expect(encodedResultEvent.count <= budget.maxJournalEventBytes)
  }

  @Test
  func runtimeBoundsInitialInputBeforeLifecycleStarts() async throws {
    let message = Message(
      role: .user,
      content: [.text(String(repeating: "input", count: 256))]
    )
    let encodedBytes = try JSONEncoder().encode([message]).count
    let budget = try AgentRunBudget(maxInitialInputBytes: encodedBytes - 1)
    let provider = provider(scripts: [])
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: ScriptedToolExecutor(tools: []),
      journal: journal,
      configuration: AgentRuntimeConfiguration(budget: budget)
    )

    await expectBudgetExceeded {
      _ = try await runtime.run(RuntimeTestFixture.request(messages: [message]))
    }

    #expect(await journal.events().isEmpty)
    #expect(await provider.requests().isEmpty)
  }

  @Test
  func runtimeBoundsDiscoveredToolCountAndSerializedDefinitions() async throws {
    let countProvider = provider(scripts: [])
    let countBudget = try AgentRunBudget(maxDiscoveredTools: 1)
    let countExecutor = ScriptedToolExecutor(
      tools: [RuntimeTestFixture.tool("one"), RuntimeTestFixture.tool("two")]
    )
    let countRuntime = RuntimeTestFixture.runtime(
      provider: countProvider,
      executor: countExecutor,
      configuration: AgentRuntimeConfiguration(budget: countBudget)
    )
    await expectBudgetExceeded {
      _ = try await countRuntime.run(RuntimeTestFixture.request())
    }
    #expect(await countProvider.requests().isEmpty)

    let definition = ToolDefinition(
      name: "large-schema",
      description: String(repeating: "schema", count: 256),
      inputSchema: ["type": .string("object")]
    )
    let definitionBytes = try JSONEncoder().encode([definition]).count
    let schemaBudget = try AgentRunBudget(
      maxSerializedToolDefinitionsBytes: definitionBytes - 1
    )
    let schemaProvider = provider(scripts: [])
    let schemaRuntime = RuntimeTestFixture.runtime(
      provider: schemaProvider,
      executor: ScriptedToolExecutor(tools: [definition]),
      configuration: AgentRuntimeConfiguration(budget: schemaBudget)
    )
    await expectBudgetExceeded {
      _ = try await schemaRuntime.run(RuntimeTestFixture.request())
    }
    #expect(await schemaProvider.requests().isEmpty)
  }

  @Test
  func accumulatorEnforcesEventTextAndSerializedByteLimits() throws {
    let eventBudget = try AgentRunBudget(maxProviderEventsPerTurn: 2)
    var eventAccumulator = makeAccumulator(budget: eventBudget)
    try eventAccumulator.accept(.started(providerResponseID: nil))
    try eventAccumulator.accept(.textDelta("ok"))
    #expect(throws: AgentRuntimeError.self) {
      try eventAccumulator.accept(.completed(.stop))
    }

    let textBudget = try AgentRunBudget(maxTextBytesPerTurn: 3)
    var textAccumulator = makeAccumulator(budget: textBudget)
    try textAccumulator.accept(.started(providerResponseID: nil))
    #expect(throws: AgentRuntimeError.self) {
      try textAccumulator.accept(.textDelta("four"))
    }

    let serializedBudget = try AgentRunBudget(
      maxTextBytesPerTurn: 1,
      maxSerializedOutputBytesPerTurn: 1
    )
    var serializedAccumulator = makeAccumulator(budget: serializedBudget)
    #expect(throws: AgentRuntimeError.self) {
      try serializedAccumulator.accept(.started(providerResponseID: nil))
    }
  }

  @Test
  func providerEventsBeyondCountOrTextBoundsNeverBecomeDurable() async throws {
    let countProvider = provider(
      scripts: [.events(RuntimeTestFixture.textEvents("within"))]
    )
    let countJournal = RecordingEventJournal()
    let countBudget = try AgentRunBudget(maxProviderEventsPerTurn: 2)
    let countRuntime = RuntimeTestFixture.runtime(
      provider: countProvider,
      executor: ScriptedToolExecutor(tools: []),
      journal: countJournal,
      configuration: AgentRuntimeConfiguration(budget: countBudget)
    )
    await expectBudgetExceeded {
      _ = try await countRuntime.run(RuntimeTestFixture.request())
    }
    let countEvents = await countJournal.events().compactMap { event in
      if case .inferenceEvent(let inferenceEvent) = event { return inferenceEvent }
      return nil
    }
    #expect(countEvents.count == 2)
    #expect(!countEvents.contains { if case .completed = $0 { true } else { false } })

    let textProvider = provider(
      scripts: [.events(RuntimeTestFixture.textEvents("four"))]
    )
    let textJournal = RecordingEventJournal()
    let textBudget = try AgentRunBudget(maxTextBytesPerTurn: 3)
    let textRuntime = RuntimeTestFixture.runtime(
      provider: textProvider,
      executor: ScriptedToolExecutor(tools: []),
      journal: textJournal,
      configuration: AgentRuntimeConfiguration(budget: textBudget)
    )
    await expectBudgetExceeded {
      _ = try await textRuntime.run(RuntimeTestFixture.request())
    }
    let textEvents = await textJournal.events().compactMap { event in
      if case .inferenceEvent(let inferenceEvent) = event { return inferenceEvent }
      return nil
    }
    #expect(textEvents == [.started(providerResponseID: "response-1")])
  }

  @Test
  func tokenBudgetCountsInputAndOutputWithoutDoubleCountingSubsets() throws {
    let budget = try AgentRunBudget(maxReportedTokens: 2)
    var accumulator = makeAccumulator(budget: budget)
    try accumulator.accept(.started(providerResponseID: nil))
    try accumulator.accept(.textDelta("ok"))
    try accumulator.accept(
      .usage(
        InferenceUsage(
          inputTokens: 1,
          outputTokens: 1,
          cachedInputTokens: 1,
          reasoningTokens: 1
        )
      )
    )
    try accumulator.accept(.completed(.stop))

    let output = try accumulator.finish()

    #expect(output.reportedTokens == 2)
  }

  @Test
  func tokenAccountingRejectsInvalidDetailSubsets() throws {
    var cached = makeAccumulator(budget: .standard)
    try cached.accept(.started(providerResponseID: nil))
    #expect(throws: AgentRuntimeError.self) {
      try cached.accept(
        .usage(InferenceUsage(inputTokens: 1, outputTokens: 1, cachedInputTokens: 2))
      )
    }

    var reasoning = makeAccumulator(budget: .standard)
    try reasoning.accept(.started(providerResponseID: nil))
    #expect(throws: AgentRuntimeError.self) {
      try reasoning.accept(
        .usage(InferenceUsage(inputTokens: 1, outputTokens: 1, reasoningTokens: 2))
      )
    }
  }

  @Test
  func tokenAccountingRejectsLimitAndOverflow() throws {
    let budget = try AgentRunBudget(maxReportedTokens: 3)
    var overLimit = makeAccumulator(budget: budget)
    try overLimit.accept(.started(providerResponseID: nil))
    #expect(throws: AgentRuntimeError.self) {
      try overLimit.accept(.usage(InferenceUsage(inputTokens: 2, outputTokens: 2)))
    }

    var overflow = makeAccumulator(budget: .standard)
    try overflow.accept(.started(providerResponseID: nil))
    #expect(throws: AgentRuntimeError.self) {
      try overflow.accept(
        .usage(InferenceUsage(inputTokens: UInt64.max, outputTokens: 1))
      )
    }
  }

  @Test
  func runtimeEnforcesTotalToolCallBudgetBeforeAuthorization() async throws {
    let calls = [
      ToolCall(id: ToolCallID(rawValue: "one"), name: "echo", arguments: [:]),
      ToolCall(id: ToolCallID(rawValue: "two"), name: "echo", arguments: [:]),
    ]
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [RuntimeTestFixture.model()],
      scripts: [.events(RuntimeTestFixture.toolEvents(calls))]
    )
    let executor = ScriptedToolExecutor(tools: [RuntimeTestFixture.tool()])
    let authorization = ScriptedAuthorizationProvider()
    let journal = RecordingEventJournal()
    let budget = try AgentRunBudget(maxToolCalls: 1)
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: executor,
      authorization: authorization,
      journal: journal,
      configuration: AgentRuntimeConfiguration(budget: budget)
    )

    await expectBudgetExceeded { _ = try await runtime.run(RuntimeTestFixture.request()) }

    #expect(await authorization.requests().isEmpty)
    #expect(await executor.calls().isEmpty)
    let events = await journal.events()
    let inferenceEvents = events.compactMap { event in
      if case .inferenceEvent(let inferenceEvent) = event { return inferenceEvent }
      return nil
    }
    #expect(inferenceEvents.count == 2)
    #expect(
      !inferenceEvents.contains { event in
        if case .toolCall(let call) = event { return call.id == calls[1].id }
        return false
      }
    )
    #expect(events.contains { if case .runFailed = $0 { true } else { false } })
  }

  @Test
  func runtimeEnforcesTurnBudgetBeforeOpeningAnotherStream() async throws {
    let call = ToolCall(
      id: ToolCallID(rawValue: "turn-limit"),
      name: "echo",
      arguments: [:]
    )
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [RuntimeTestFixture.model()],
      scripts: [.events(RuntimeTestFixture.toolEvents([call]))]
    )
    let executor = ScriptedToolExecutor(tools: [RuntimeTestFixture.tool()])
    let budget = try AgentRunBudget(maxTurns: 1)
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: executor,
      configuration: AgentRuntimeConfiguration(budget: budget)
    )

    await expectBudgetExceeded { _ = try await runtime.run(RuntimeTestFixture.request()) }

    #expect(await provider.requests().count == 1)
    #expect(await executor.calls().count == 1)
  }

  @Test
  func runtimeEnforcesReportedTokensAcrossTurns() async throws {
    let call = ToolCall(
      id: ToolCallID(rawValue: "token-limit"),
      name: "echo",
      arguments: [:]
    )
    let firstEvents: [InferenceStreamEvent] = [
      .started(providerResponseID: nil),
      .toolCall(call),
      .usage(InferenceUsage(inputTokens: 2, outputTokens: 1)),
      .completed(.toolCalls),
    ]
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [RuntimeTestFixture.model()],
      scripts: [
        .events(firstEvents),
        .events(
          RuntimeTestFixture.textEvents(
            "done",
            usage: InferenceUsage(inputTokens: 2, outputTokens: 1)
          )
        ),
      ]
    )
    let budget = try AgentRunBudget(maxReportedTokens: 5)
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: ScriptedToolExecutor(tools: [RuntimeTestFixture.tool()]),
      journal: journal,
      configuration: AgentRuntimeConfiguration(budget: budget)
    )

    await expectBudgetExceeded { _ = try await runtime.run(RuntimeTestFixture.request()) }

    let usageEvents = await journal.events().reduce(into: 0) { count, event in
      if case .inferenceEvent(.usage) = event { count += 1 }
    }
    #expect(usageEvents == 1)
  }

  @Test
  func runtimeBoundsEachReturnedToolResultBeforeJournalingIt() async throws {
    let call = ToolCall(
      id: ToolCallID(rawValue: "large-result"),
      name: "echo",
      arguments: [:]
    )
    let result = ToolResult(
      toolCallID: call.id,
      status: .success,
      output: .string(String(repeating: "result", count: 256))
    )
    let resultBytes = try JSONEncoder().encode(result).count
    let budget = try AgentRunBudget(maxToolResultBytes: resultBytes - 1)
    let provider = provider(scripts: [.events(RuntimeTestFixture.toolEvents([call]))])
    let executor = ScriptedToolExecutor(
      tools: [RuntimeTestFixture.tool()],
      behaviors: [.result(result)]
    )
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: executor,
      journal: journal,
      configuration: AgentRuntimeConfiguration(budget: budget)
    )

    await expectBudgetExceeded { _ = try await runtime.run(RuntimeTestFixture.request()) }

    #expect(await executor.calls().map(\.id) == [call.id])
    let events = await journal.events()
    #expect(events.contains { if case .toolStarted = $0 { true } else { false } })
    #expect(!events.contains { if case .toolFinished = $0 { true } else { false } })
  }

  @Test
  func runtimeBoundsCumulativeToolResultsWithOverflowSafeAccounting() async throws {
    let firstCall = ToolCall(
      id: ToolCallID(rawValue: "result-one"),
      name: "echo",
      arguments: [:]
    )
    let secondCall = ToolCall(
      id: ToolCallID(rawValue: "result-two"),
      name: "echo",
      arguments: [:]
    )
    let firstResult = ToolResult(
      toolCallID: firstCall.id,
      status: .success,
      output: .string(String(repeating: "a", count: 128))
    )
    let secondResult = ToolResult(
      toolCallID: secondCall.id,
      status: .success,
      output: .string(String(repeating: "b", count: 128))
    )
    let firstBytes = try JSONEncoder().encode(firstResult).count
    let secondBytes = try JSONEncoder().encode(secondResult).count
    let budget = try AgentRunBudget(
      maxToolResultBytes: max(firstBytes, secondBytes),
      maxTotalToolResultBytes: firstBytes + secondBytes - 1
    )
    let provider = provider(
      scripts: [.events(RuntimeTestFixture.toolEvents([firstCall, secondCall]))]
    )
    let executor = ScriptedToolExecutor(
      tools: [RuntimeTestFixture.tool()],
      behaviors: [.result(firstResult), .result(secondResult)]
    )
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: executor,
      journal: journal,
      configuration: AgentRuntimeConfiguration(budget: budget)
    )

    await expectBudgetExceeded { _ = try await runtime.run(RuntimeTestFixture.request()) }

    #expect(await executor.calls().map(\.id) == [firstCall.id, secondCall.id])
    let finishedIDs = await journal.events().compactMap { event in
      if case .toolFinished(let result) = event { return result.toolCallID }
      return nil
    }
    #expect(finishedIDs == [firstCall.id, secondCall.id])
    let toolMessageCount = await journal.events().reduce(into: 0) { count, event in
      if case .messageAppended(let message) = event, message.role == .tool { count += 1 }
    }
    #expect(toolMessageCount == 1)
  }

  @Test
  func oversizedDenialReasonIsRejectedBeforeDecisionIsJournaled() async throws {
    let call = ToolCall(
      id: ToolCallID(rawValue: "large-denial"),
      name: "echo",
      arguments: [:]
    )
    let provider = provider(scripts: [.events(RuntimeTestFixture.toolEvents([call]))])
    let executor = ScriptedToolExecutor(tools: [RuntimeTestFixture.tool()])
    let authorization = ScriptedAuthorizationProvider(
      mode: .decisions([.deny(reason: String(repeating: "private", count: 256))])
    )
    let budget = try AgentRunBudget(maxToolResultBytes: 128)
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: executor,
      authorization: authorization,
      journal: journal,
      configuration: AgentRuntimeConfiguration(budget: budget)
    )

    await expectBudgetExceeded { _ = try await runtime.run(RuntimeTestFixture.request()) }

    #expect(await executor.calls().isEmpty)
    let events = await journal.events()
    #expect(events.contains { if case .authorizationRequested = $0 { true } else { false } })
    #expect(!events.contains { if case .authorizationDecided = $0 { true } else { false } })
    #expect(!events.contains { if case .toolFinished = $0 { true } else { false } })
  }

  @Test
  func cumulativeDeniedResultsAreBoundedBeforeAnyExecution() async throws {
    let firstCall = ToolCall(
      id: ToolCallID(rawValue: "denied-one"),
      name: "echo",
      arguments: [:]
    )
    let secondCall = ToolCall(
      id: ToolCallID(rawValue: "denied-two"),
      name: "echo",
      arguments: [:]
    )
    let reason = String(repeating: "denied", count: 32)
    let firstResult = ToolResult(
      toolCallID: firstCall.id,
      status: .failure,
      output: .object([
        "error": .string("authorization_denied"),
        "reason": .string(reason),
      ])
    )
    let secondResult = ToolResult(
      toolCallID: secondCall.id,
      status: .failure,
      output: .object([
        "error": .string("authorization_denied"),
        "reason": .string(reason),
      ])
    )
    let firstBytes = try JSONEncoder().encode(firstResult).count
    let secondBytes = try JSONEncoder().encode(secondResult).count
    let budget = try AgentRunBudget(
      maxToolResultBytes: max(firstBytes, secondBytes),
      maxTotalToolResultBytes: firstBytes + secondBytes - 1
    )
    let provider = provider(
      scripts: [.events(RuntimeTestFixture.toolEvents([firstCall, secondCall]))]
    )
    let executor = ScriptedToolExecutor(tools: [RuntimeTestFixture.tool()])
    let authorization = ScriptedAuthorizationProvider(
      mode: .decisions([.deny(reason: reason), .deny(reason: reason)])
    )
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: executor,
      authorization: authorization,
      journal: journal,
      configuration: AgentRuntimeConfiguration(budget: budget)
    )

    await expectBudgetExceeded { _ = try await runtime.run(RuntimeTestFixture.request()) }

    #expect(await authorization.requests().count == 2)
    #expect(await executor.calls().isEmpty)
    let events = await journal.events()
    let decisionCount = events.reduce(into: 0) { count, event in
      if case .authorizationDecided = event { count += 1 }
    }
    #expect(decisionCount == 1)
    #expect(!events.contains { if case .toolStarted = $0 { true } else { false } })
    #expect(!events.contains { if case .toolFinished = $0 { true } else { false } })
  }

  @Test
  func conversationGrowthIsBoundedBeforeOpeningNextInference() async throws {
    let call = ToolCall(
      id: ToolCallID(rawValue: "conversation-growth"),
      name: "echo",
      arguments: [:]
    )
    let result = ToolResult(
      toolCallID: call.id,
      status: .success,
      output: .string(String(repeating: "growth", count: 64))
    )
    let request = RuntimeTestFixture.request()
    let representativeConversation =
      request.initialMessages
      + [
        Message(role: .assistant, content: [.toolCall(call)]),
        Message(role: .tool, content: [.toolResult(result)]),
      ]
    let grownBytes = try JSONEncoder().encode(representativeConversation).count
    let initialBytes = try JSONEncoder().encode(request.initialMessages).count
    let budget = try AgentRunBudget(
      maxInitialInputBytes: initialBytes,
      maxConversationBytes: grownBytes - 1
    )
    let provider = provider(scripts: [.events(RuntimeTestFixture.toolEvents([call]))])
    let executor = ScriptedToolExecutor(
      tools: [RuntimeTestFixture.tool()],
      behaviors: [.result(result)]
    )
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: executor,
      journal: journal,
      configuration: AgentRuntimeConfiguration(budget: budget)
    )

    await expectBudgetExceeded { _ = try await runtime.run(request) }

    #expect(await provider.requests().count == 1)
    #expect(await executor.calls().count == 1)
    let events = await journal.events()
    #expect(events.contains { if case .toolFinished = $0 { true } else { false } })
    #expect(
      !events.contains { event in
        if case .messageAppended(let message) = event { return message.role == .tool }
        return false
      }
    )
  }

  @Test
  func finalAssistantMessageCannotExceedConversationBudget() async throws {
    let text = String(repeating: "final", count: 128)
    let request = RuntimeTestFixture.request()
    let representativeConversation =
      request.initialMessages
      + [
        Message(role: .assistant, content: [.text(text)])
      ]
    let initialBytes = try JSONEncoder().encode(request.initialMessages).count
    let grownBytes = try JSONEncoder().encode(representativeConversation).count
    let budget = try AgentRunBudget(
      maxInitialInputBytes: initialBytes,
      maxConversationBytes: grownBytes - 1
    )
    let provider = provider(scripts: [.events(RuntimeTestFixture.textEvents(text))])
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: ScriptedToolExecutor(tools: []),
      journal: journal,
      configuration: AgentRuntimeConfiguration(budget: budget)
    )

    await expectBudgetExceeded { _ = try await runtime.run(request) }

    #expect(await provider.requests().count == 1)
    let events = await journal.events()
    #expect(
      !events.contains { event in
        if case .messageAppended(let message) = event { return message.role == .assistant }
        return false
      }
    )
    #expect(!events.contains { if case .runCompleted = $0 { true } else { false } })
  }

  private func makeAccumulator(budget: AgentRunBudget) -> InferenceTurnAccumulator {
    InferenceTurnAccumulator(
      budget: budget,
      allowedToolNames: [],
      priorToolCallIDs: [],
      remainingToolCalls: budget.maxToolCalls,
      remainingReportedTokens: budget.maxReportedTokens,
      allowsParallelToolCalls: true
    )
  }

  private func provider(scripts: [InferenceScript]) -> ScriptedInferenceProvider {
    ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [RuntimeTestFixture.model()],
      scripts: scripts
    )
  }

  private func expectBudgetExceeded(
    _ operation: @escaping @Sendable () async throws -> Void
  ) async {
    do {
      try await operation()
      Issue.record("Expected budgetExceeded.")
    } catch AgentRuntimeError.budgetExceeded {
      // Expected bounded failure.
    } catch {
      Issue.record("Expected budgetExceeded, received: \(error)")
    }
  }
}
