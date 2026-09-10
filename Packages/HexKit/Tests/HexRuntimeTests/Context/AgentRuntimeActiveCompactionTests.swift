import Foundation
import HexCore
import HexRuntime
import Testing

@Suite("Active tool-loop compaction")
struct AgentRuntimeActiveCompactionTests {
  @Test
  func resumableHistoryBeyondTwoMiBCompactsBeforeInferenceWithoutLosingTheNewRequest() async throws
  {
    let calls = (0..<2).map { _ in ToolCall(name: "echo", arguments: [:]) }
    let previous = Message(role: .user, content: [.text("Inspect the existing project.")])
    let results = calls.map {
      let result = ToolResult(
        toolCallID: $0.id, status: .success,
        output: .string(String(repeating: "evidence", count: 140_000)))
      return Message(role: .tool, content: [.toolResult(result)])
    }
    let current = Message(role: .user, content: [.text("Now show me the finished project.")])
    let messages =
      [previous, Message(role: .assistant, content: calls.map(MessageContent.toolCall))]
      + results + [current]
    let encoded = try JSONEncoder().encode(messages)
    #expect(encoded.count > 2_097_152)
    #expect(encoded.count < AgentRunBudget.standard.maxConversationBytes)
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(), models: [RuntimeTestFixture.model()],
      scripts: [.events(RuntimeTestFixture.textEvents("Finished"))])
    let journal = RecordingEventJournal()
    let runtime = AgentRuntime(
      inferenceProvider: provider, toolExecutor: ScriptedToolExecutor(tools: []),
      authorizationProvider: ScriptedAuthorizationProvider(), journal: journal,
      contextSummarizer: HistorySummary())
    _ = try await runtime.run(RuntimeTestFixture.request(messages: messages))
    let request = try #require(await provider.requests().first)
    #expect(request.messages.contains(current))
    #expect(!request.messages.contains(results[0]))
    #expect(request.previousProviderResponseID == nil)
    let events = await journal.events()
    #expect(events.contains(.messageAppended(results[0])))
    #expect(events.contains(.messageAppended(results[1])))
    #expect(
      events.contains {
        if case .contextCompacted = $0 { return true }
        return false
      })
  }

  @Test
  func repeatedCompactionRetainsGoalAndStartsFreshProviderRequests() async throws {
    let calls = (0..<4).map { _ in ToolCall(id: ToolCallID(), name: "echo", arguments: [:]) }
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [
        ModelDescriptor(
          id: RuntimeTestFixture.modelID, providerID: RuntimeTestFixture.providerID,
          displayName: "Small", capabilities: RuntimeTestFixture.standardCapabilities,
          contextWindow: 8_192, maxOutputTokens: 256)
      ],
      scripts: calls.map { .events(RuntimeTestFixture.toolEvents([$0])) }
        + [.events(RuntimeTestFixture.textEvents("Finished"))])
    let executor = ScriptedToolExecutor(
      tools: [RuntimeTestFixture.tool()],
      behaviors: calls.map {
        .result(
          ToolResult(
            toolCallID: $0.id, status: .success,
            output: .string(String(repeating: "evidence ", count: 700))))
      })
    let journal = RecordingEventJournal()
    let goal = Message(
      role: .user, content: [.text("Inspect four items; never repeat completed work.")])
    let runtime = AgentRuntime(
      inferenceProvider: provider, toolExecutor: executor,
      authorizationProvider: ScriptedAuthorizationProvider(), journal: journal,
      contextSummarizer: Summary())
    let result = try await runtime.run(RuntimeTestFixture.request(messages: [goal]))
    let requests = await provider.requests()
    #expect(result.toolCallCount == 4)
    #expect(await executor.calls() == calls)
    #expect(requests.count == 5)
    #expect(requests.allSatisfy { $0.messages.first == goal })
    let compactions = await journal.events().compactMap { event -> AgentContextCompaction? in
      if case .contextCompacted(let record) = event { return record }
      return nil
    }
    #expect(compactions.count >= 2)
    for record in compactions {
      let request = try #require(requests.first { $0.messages.contains(record.summaryMessage) })
      #expect(request.previousProviderResponseID == nil)
      #expect(!record.sourceMessageIDs.contains(goal.id))
      #expect(record.taskMessageID == goal.id)
      #expect(
        record.summaryMessage.content == [
          .text(AgentContextCompaction.activeSummaryLabel + record.summaryText)
        ])
    }
    #expect(result.totalReportedTokens == UInt64(compactions.count * 3))
  }

  @Test(arguments: [false, true])
  func failedOrCancelledSummaryPreservesToolEvidenceAndStopsInference(cancel: Bool) async throws {
    let call = ToolCall(name: "echo", arguments: [:])
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [
        ModelDescriptor(
          id: RuntimeTestFixture.modelID,
          providerID: RuntimeTestFixture.providerID, displayName: "Small",
          capabilities: RuntimeTestFixture.standardCapabilities,
          contextWindow: 8_192, maxOutputTokens: 256)
      ],
      scripts: [.events(RuntimeTestFixture.toolEvents([call]))])
    let result = ToolResult(
      toolCallID: call.id, status: .success,
      output: .string(String(repeating: "evidence ", count: 900)))
    let executor = ScriptedToolExecutor(
      tools: [RuntimeTestFixture.tool()],
      behaviors: [.result(result)])
    let journal = RecordingEventJournal()
    let runtime = AgentRuntime(
      inferenceProvider: provider, toolExecutor: executor,
      authorizationProvider: ScriptedAuthorizationProvider(), journal: journal,
      contextSummarizer: FailingSummary(cancel: cancel))
    do {
      _ = try await runtime.run(RuntimeTestFixture.request())
      Issue.record("Expected summary failure")
    } catch is CancellationError {
      #expect(cancel)
    } catch let error as AgentRuntimeError {
      #expect(!cancel)
      guard case .providerFailure = error else {
        Issue.record("Wrong error: \(error)")
        return
      }
    }
    let events = await journal.events()
    #expect(events.contains(.toolFinished(result)))
    #expect(events.contains(.contextCompactionStarted))
    #expect(
      !events.contains {
        if case .contextCompacted = $0 { return true }
        return false
      })
    #expect(await provider.requests().count == 1)
    #expect(await executor.calls() == [call])
  }

  @Test
  func unknownImageCostDoesNotBypassInitialAdmission() async throws {
    let capabilities = RuntimeTestFixture.standardCapabilities.union([.imageInput])
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(capabilities: capabilities),
      models: [RuntimeTestFixture.model(capabilities: capabilities)], scripts: [])
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: ScriptedToolExecutor(tools: []))
    let url = try #require(URL(string: "https://example.invalid/image.png"))
    let request = RuntimeTestFixture.request(messages: [
      Message(
        role: .user,
        content: [.image(ImageContent(sourceURL: url, mediaType: "image/png"))])
    ])
    do {
      _ = try await runtime.run(request)
      Issue.record("Expected unknown image cost to fail admission")
    } catch let error as AgentRuntimeError {
      guard case .budgetExceeded(let message) = error else {
        Issue.record("Wrong error: \(error)")
        return
      }
      #expect(message.contains("image context cost"))
    }
    #expect(await provider.requests().isEmpty)
  }

  private struct HistorySummary: AgentContextSummarizing {
    func summarize(_ request: AgentContextSummaryRequest) async throws -> AgentContextSummaryResult
    {
      AgentContextSummaryResult(
        text: "The project was inspected; show the finished result.",
        reportedTokens: 3, inferenceCalls: 1)
    }
  }

  private struct FailingSummary: AgentContextSummarizing {
    let cancel: Bool
    func summarize(_ request: AgentContextSummaryRequest) async throws -> AgentContextSummaryResult
    {
      if cancel { throw CancellationError() }
      throw AgentRuntimeError.invalidRequest("Fixture summary failure")
    }
  }

  private struct Summary: AgentContextSummarizing {
    func summarize(_ request: AgentContextSummaryRequest) async throws -> AgentContextSummaryResult
    {
      #expect(request.currentTask?.role == .user)
      #expect(!request.sourceMessages.contains { $0.id == request.currentTask?.id })
      return AgentContextSummaryResult(
        text: "Completed observations retained; continue remaining items.",
        reportedTokens: 3, inferenceCalls: 1)
    }
  }
}
