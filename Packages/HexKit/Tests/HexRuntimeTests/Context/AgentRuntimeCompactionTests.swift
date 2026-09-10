import Foundation
import HexCore
import HexRuntime
import Testing

@Suite("Automatic runtime compaction")
struct AgentRuntimeCompactionTests {
  @Test
  func boundaryStopCancelsASummaryAndKeepsOriginalHistory() async {
    let original = history()
    let provider = provider(scripts: [.suspend])
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider, executor: ScriptedToolExecutor(tools: []), journal: journal)
    let request = RuntimeTestFixture.request(messages: original)
    let task = Task { try await runtime.run(request) }
    for _ in 0..<200 {
      if await provider.requests().count == 1 { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(await provider.requests().count == 1)
    await runtime.stopAtBoundary(request.runID)
    for _ in 0..<200 {
      if await journal.events().contains(where: {
        if case .runCancelled = $0 { true } else { false }
      }) {
        break
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    let events = await journal.events()
    #expect(events.contains { if case .contextCompactionStarted = $0 { true } else { false } })
    #expect(events.contains { if case .runCancelled = $0 { true } else { false } })
    #expect(!events.contains { if case .contextCompacted = $0 { true } else { false } })
    #expect(original.allSatisfy { events.contains(.messageAppended($0)) })
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Expected summary cancellation")
    } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
  }

  @Test
  func priorLargeExchangeUsesBoundedSummaryBatchesBeforeResumingTheNewRequest() async throws {
    let batches = (0..<5).flatMap { index -> [Message] in
      let call = ToolCall(name: "inspect", arguments: [:])
      return [
        Message(role: .assistant, content: [.toolCall(call)]),
        Message(
          role: .tool,
          content: [
            .toolResult(
              ToolResult(
                toolCallID: call.id, status: .success,
                output: .string("File \(index): " + String(repeating: "x", count: 1_500))))
          ]),
      ]
    }
    let original =
      [Message(role: .user, content: [.text("Inspect the project")])]
      + batches + [Message(role: .user, content: [.text("Continue with the design changes")])]
    let provider = provider(
      scripts: Array(
        repeating: .events(
          RuntimeTestFixture.textEvents("The files were inspected; design changes remain.")),
        count: 8))
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider, executor: ScriptedToolExecutor(tools: []), journal: journal)
    _ = try await runtime.run(RuntimeTestFixture.request(messages: original))
    let requests = await provider.requests()
    #expect(requests.count > 2)
    #expect(requests.last?.messages.last == original.last)
    let events = await journal.events()
    let checkpoint = try #require(
      events.compactMap { event -> AgentContextCompaction? in
        if case .contextCompacted(let value) = event { return value }
        return nil
      }.first)
    #expect(checkpoint.sourceMessageIDs == original.dropLast().map(\.id))
    #expect(checkpoint.inferenceCalls == requests.count - 1)
    #expect(original.allSatisfy { events.contains(.messageAppended($0)) })
  }

  @Test
  func followUpAfterOneOversizedAttemptCanResumeWithADurableCheckpoint() async throws {
    let call = ToolCall(name: "echo", arguments: [:])
    let receipt = ToolResult(
      toolCallID: call.id, status: .success, output: .string(String(repeating: "x", count: 9_000)))
    let original = [
      Message(role: .user, content: [.text("Build my site")]),
      Message(role: .assistant, content: [.toolCall(call)]),
      Message(role: .tool, content: [.toolResult(receipt)]),
      Message(role: .user, content: [.text("Continue and improve the contrast")]),
    ]
    let provider = provider(scripts: [.events(RuntimeTestFixture.textEvents())])
    let journal = RecordingEventJournal()
    let runtime = AgentRuntime(
      inferenceProvider: provider, toolExecutor: ScriptedToolExecutor(tools: []),
      authorizationProvider: ScriptedAuthorizationProvider(), journal: journal,
      contextSummarizer: UsageSummarizer(reportedTokens: 1))
    _ = try await runtime.run(RuntimeTestFixture.request(messages: original))
    let inference = try #require(await provider.requests().first)
    #expect(inference.messages.last == original.last)
    #expect(inference.messages.count == 2)
    #expect(inference.previousProviderResponseID == nil)
    let events = await journal.events()
    #expect(original.allSatisfy { events.contains(.messageAppended($0)) })
    let checkpoint = try #require(
      events.compactMap { event -> AgentContextCompaction? in
        if case .contextCompacted(let value) = event { return value }
        return nil
      }.first)
    #expect(checkpoint.sourceMessageIDs == original.prefix(3).map(\.id))
    #expect(checkpoint.summaryMessage == inference.messages.first)
    #expect(checkpoint.estimatedTokensAfter < checkpoint.estimatedTokensBefore)
  }

  @Test
  func nearFullAdmissionCondensesOldHistoryAndKeepsTheNextFileReadIntact() async throws {
    let original =
      Array(history().prefix(8)) + [
        Message(role: .user, content: [.text("Finish the current design")])
      ]
    let model = ModelDescriptor(
      id: RuntimeTestFixture.modelID, providerID: RuntimeTestFixture.providerID,
      displayName: "Working headroom", capabilities: RuntimeTestFixture.standardCapabilities,
      contextWindow: 16_384, maxOutputTokens: 4_096)
    let call = ToolCall(name: "echo", arguments: [:])
    let file = ToolResult(
      toolCallID: call.id, status: .success, output: .string(String(repeating: "x", count: 3_000)))
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(), models: [model],
      scripts: [
        .events(RuntimeTestFixture.toolEvents([call])),
        .events(RuntimeTestFixture.textEvents()),
      ])
    let journal = RecordingEventJournal()
    let runtime = AgentRuntime(
      inferenceProvider: provider,
      toolExecutor: ScriptedToolExecutor(
        tools: [RuntimeTestFixture.tool()], behaviors: [.result(file)]),
      authorizationProvider: ScriptedAuthorizationProvider(), journal: journal,
      contextSummarizer: UsageSummarizer(reportedTokens: 1))
    _ = try await runtime.run(RuntimeTestFixture.request(messages: original))
    let requests = await provider.requests()
    #expect(requests.count == 2)
    #expect(requests.first?.messages.contains(try #require(original.last)) == true)
    #expect(
      requests.last?.messages.contains(where: { $0.content.contains(.toolResult(file)) }) == true)
    let events = await journal.events()
    let compactions = events.compactMap { event -> AgentContextCompaction? in
      if case .contextCompacted(let value) = event { return value }
      return nil
    }
    #expect(compactions.count == 1)
    #expect(compactions.first?.boundary == nil)
    #expect(events.contains(.messageAppended(original[0])))
  }

  @Test
  func headroomPreferenceDoesNotRejectAnIrreducibleRequestThatFits() async throws {
    let original = Message(role: .user, content: [.text(String(repeating: "x", count: 10_000))])
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [
        ModelDescriptor(
          id: RuntimeTestFixture.modelID, providerID: RuntimeTestFixture.providerID,
          displayName: "Working headroom", capabilities: RuntimeTestFixture.standardCapabilities,
          contextWindow: 16_384, maxOutputTokens: 4_096)
      ], scripts: [.events(RuntimeTestFixture.textEvents())])
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider, executor: ScriptedToolExecutor(tools: [RuntimeTestFixture.tool()]),
      journal: journal)
    _ = try await runtime.run(RuntimeTestFixture.request(messages: [original]))
    #expect(await provider.requests().first?.messages == [original])
    #expect(try !containsEvent("contextCompacted", events: await journal.events()))
  }

  @Test
  func oversizedHistoryIsSummarizedBeforePrimaryInferenceWithoutDeletingOriginalEvents()
    async throws
  {
    let original = history()
    let pinned = Message(
      role: .developer, content: [.text("Current runtime-owned identity and permissions")])
    let provider = provider(
      scripts: Array(
        repeating: .events(
          RuntimeTestFixture.textEvents(
            "Decisions and completed work, with unresolved work preserved.")), count: 16))
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: ScriptedToolExecutor(tools: []), journal: journal)
    _ = try await runtime.run(
      AgentRunRequest(
        runID: AgentRunID(), modelID: RuntimeTestFixture.modelID,
        initialMessages: original, contextMessages: [pinned]))
    let requests = await provider.requests()
    #expect(requests.count > 1)
    let primary = try #require(requests.last)
    #expect(primary.messages.count < original.count)
    #expect(primary.messages.first == pinned)
    #expect(primary.messages.last == original.last)
    #expect(primary.previousProviderResponseID == nil)
    let events = await journal.events()
    let appended = events.compactMap { event -> Message? in
      if case .messageAppended(let message) = event { return message }
      return nil
    }
    #expect(Array(appended.prefix(original.count)) == original)
    #expect(try containsEvent("contextCompacted", events: events))
  }

  @Test
  func irreducibleCurrentRequestDoesNotCallTheProviderOrClipThePrompt() async throws {
    let provider = provider(scripts: [.events(RuntimeTestFixture.textEvents())])
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: ScriptedToolExecutor(tools: []), journal: journal)
    let original = Message(role: .user, content: [.text(String(repeating: "x", count: 20_000))])
    do {
      _ = try await runtime.run(RuntimeTestFixture.request(messages: [original]))
      Issue.record("Expected explicit context overflow without a provider call.")
    } catch let error as AgentRuntimeError {
      guard case .budgetExceeded = error else {
        Issue.record("Wrong error: \(error)")
        return
      }
    }
    #expect(await provider.requests().isEmpty)
    #expect(await journal.events().contains(.messageAppended(original)))
  }

  @Test
  func failedSummaryLeavesOriginalEventsAndDoesNotPublishACompaction() async throws {
    let provider = provider(scripts: [.openingFailure])
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: ScriptedToolExecutor(tools: []), journal: journal)
    let original = history()
    do {
      _ = try await runtime.run(RuntimeTestFixture.request(messages: original))
      Issue.record("Expected failed summary.")
    } catch {}
    let events = await journal.events()
    #expect(try containsEvent("contextCompactionStarted", events: events))
    #expect(try !containsEvent("contextCompacted", events: events))
    #expect(await provider.requests().count == 1)
    #expect(events.contains(.messageAppended(original[0])))
  }

  @Test
  func failedCompactionJournalAppendPreventsPrimaryInference() async throws {
    let original = history()
    let provider = provider(
      scripts: Array(
        repeating: .events(
          RuntimeTestFixture.textEvents("Completed history summary.")), count: 16))
    let journal = RecordingEventJournal(failOn: .appendNumber(original.count + 3))
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: ScriptedToolExecutor(tools: []), journal: journal)
    do {
      _ = try await runtime.run(RuntimeTestFixture.request(messages: original))
      Issue.record("Expected compaction publication failure.")
    } catch let error as AgentRuntimeError {
      guard case .journalFailure = error else {
        Issue.record("Wrong error: \(error)")
        return
      }
    }
    let requests = await provider.requests()
    #expect(!requests.isEmpty)
    #expect(requests.allSatisfy { $0.toolChoice == .none })
    #expect(try !containsEvent("contextCompacted", events: await journal.events()))
  }

  @Test
  func cancellationAfterDurableCompactionDoesNotStartPrimaryInference() async throws {
    let original = history()
    let provider = provider(
      scripts: Array(
        repeating: .events(
          RuntimeTestFixture.textEvents("Completed history summary.")), count: 16))
    let journal = RecordingEventJournal(cancelAfterPersistOn: .appendNumber(original.count + 3))
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: ScriptedToolExecutor(tools: []), journal: journal)
    let task = Task { try await runtime.run(RuntimeTestFixture.request(messages: original)) }
    do {
      _ = try await task.value
      Issue.record("Expected cancellation after publication.")
    } catch is CancellationError {}
    #expect(await provider.requests().allSatisfy { $0.toolChoice == .none })
    let events = await journal.events()
    #expect(try containsEvent("contextCompacted", events: events))
    #expect(events.last == .runCancelled)
  }

  @Test(arguments: [true, false])
  func injectedSummarizerCannotPublishAnOverbudgetOrEmptyResult(overbudget: Bool) async throws {
    let provider = provider(scripts: [])
    let journal = RecordingEventJournal()
    let runtime = AgentRuntime(
      inferenceProvider: provider,
      toolExecutor: ScriptedToolExecutor(tools: []),
      authorizationProvider: ScriptedAuthorizationProvider(), journal: journal,
      contextSummarizer: InvalidSummarizer(overbudget: overbudget))
    do {
      _ = try await runtime.run(RuntimeTestFixture.request(messages: history()))
      Issue.record("Expected invalid injected summary to fail closed.")
    } catch let error as AgentRuntimeError {
      guard case .protocolViolation = error else {
        Issue.record("Wrong error: \(error)")
        return
      }
    }
    #expect(await provider.requests().isEmpty)
    #expect(try !containsEvent("contextCompacted", events: await journal.events()))
  }

  private struct InvalidSummarizer: AgentContextSummarizing {
    let overbudget: Bool
    func summarize(_ request: AgentContextSummaryRequest) async throws -> AgentContextSummaryResult
    {
      AgentContextSummaryResult(
        text: overbudget ? "summary" : "   ",
        reportedTokens: overbudget ? UInt64.max : 0, inferenceCalls: 1)
    }
  }

  @Test
  func summaryUsageIsIncludedInTheRunTotal() async throws {
    let provider = provider(scripts: [
      .events(
        RuntimeTestFixture.textEvents(
          "Primary answer",
          usage: InferenceUsage(inputTokens: 7, outputTokens: 3)))
    ])
    let runtime = AgentRuntime(
      inferenceProvider: provider,
      toolExecutor: ScriptedToolExecutor(tools: []),
      authorizationProvider: ScriptedAuthorizationProvider(), journal: RecordingEventJournal(),
      contextSummarizer: UsageSummarizer(reportedTokens: 13))
    let result = try await runtime.run(RuntimeTestFixture.request(messages: history()))
    #expect(result.totalReportedTokens == 23)
    #expect(result.turns.count == 1)
    #expect(await provider.requests().count == 1)
  }

  @Test
  func exhaustedSummaryBudgetPreventsOpeningPrimaryInference() async throws {
    let provider = provider(scripts: [.events(RuntimeTestFixture.textEvents())])
    let journal = RecordingEventJournal()
    let runtime = AgentRuntime(
      inferenceProvider: provider,
      toolExecutor: ScriptedToolExecutor(tools: []),
      authorizationProvider: ScriptedAuthorizationProvider(), journal: journal,
      configuration: AgentRuntimeConfiguration(budget: try AgentRunBudget(maxReportedTokens: 100)),
      contextSummarizer: UsageSummarizer(reportedTokens: 100))
    do {
      _ = try await runtime.run(RuntimeTestFixture.request(messages: history()))
      Issue.record("Expected the consumed inference budget to stop new provider work.")
    } catch let error as AgentRuntimeError {
      guard case .budgetExceeded = error else {
        Issue.record("Wrong error: \(error)")
        return
      }
    }
    #expect(await provider.requests().isEmpty)
    #expect(try containsEvent("contextCompacted", events: await journal.events()))
    #expect(try !containsEvent("inferenceRequested", events: await journal.events()))
  }

  private struct UsageSummarizer: AgentContextSummarizing {
    let reportedTokens: UInt64
    let text: String

    init(reportedTokens: UInt64, text: String = "Prior task, constraints and unfinished work.") {
      self.reportedTokens = reportedTokens
      self.text = text
    }

    func summarize(_ request: AgentContextSummaryRequest) async throws -> AgentContextSummaryResult
    {
      AgentContextSummaryResult(
        text: text,
        reportedTokens: reportedTokens, inferenceCalls: 1)
    }
  }

  @Test
  func largeModelCanRetainADetailedCheckpointInsteadOfATinyFixedSummary() async throws {
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [
        ModelDescriptor(
          id: RuntimeTestFixture.modelID, providerID: RuntimeTestFixture.providerID,
          displayName: "Large context", capabilities: RuntimeTestFixture.standardCapabilities,
          contextWindow: 65_536, maxOutputTokens: 8_192)
      ], scripts: [.events(RuntimeTestFixture.textEvents())])
    let detail = String(repeating: "Relevant constraints and verified outcomes. ", count: 70)
    let runtime = AgentRuntime(
      inferenceProvider: provider,
      toolExecutor: ScriptedToolExecutor(tools: []),
      authorizationProvider: ScriptedAuthorizationProvider(), journal: RecordingEventJournal(),
      contextSummarizer: UsageSummarizer(reportedTokens: 13, text: detail))
    let original = history().map { message in
      Message(
        id: message.id, role: message.role,
        content: message.content.map { content in
          if case .text(let text) = content, text.count > 1_000 {
            return .text(text + String(repeating: " historical detail", count: 180))
          }
          return content
        })
    }
    let result = try await runtime.run(RuntimeTestFixture.request(messages: original))
    #expect(result.messages.count < original.count)
    #expect(
      result.messages.first?.content.contains(where: {
        if case .text(let text) = $0 { return text.contains(detail) }
        return false
      }) == true)
    #expect(result.messages.contains(try #require(original.last)))
  }

  private func history() -> [Message] {
    (0..<10).flatMap { index in
      [
        Message(
          role: .user, content: [.text("Question \(index) " + String(repeating: "x", count: 1_000))]
        ),
        Message(
          role: .assistant,
          content: [.text("Answer \(index) " + String(repeating: "y", count: 1_000))]),
      ]
    } + [Message(role: .user, content: [.text("Continue the task")])]
  }

  private func provider(scripts: [InferenceScript]) -> ScriptedInferenceProvider {
    ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [
        ModelDescriptor(
          id: RuntimeTestFixture.modelID, providerID: RuntimeTestFixture.providerID,
          displayName: "Small test context",
          capabilities: RuntimeTestFixture.standardCapabilities, contextWindow: 8_192,
          maxOutputTokens: 256)
      ],
      scripts: scripts)
  }

  private func containsEvent(_ key: String, events: [AgentEvent]) throws -> Bool {
    try events.contains { event in
      let object =
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
      return object?[key] != nil
    }
  }
}
