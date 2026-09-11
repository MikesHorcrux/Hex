import Foundation
import HexCore
import HexRuntime
import Testing

@Suite("AgentRuntime happy paths")
struct AgentRuntimeHappyPathTests {
  @Test
  func textOnlyRunHasExactEventOrderAndCompletion() async throws {
    let usage = InferenceUsage(
      inputTokens: 10,
      outputTokens: 5,
      cachedInputTokens: 8,
      reasoningTokens: 3
    )
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [RuntimeTestFixture.model()],
      scripts: [.events(RuntimeTestFixture.textEvents("hello", usage: usage))]
    )
    let executor = ScriptedToolExecutor(tools: [])
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: executor,
      journal: journal
    )
    let request = RuntimeTestFixture.request()

    let result = try await runtime.run(request)
    let events = await journal.events()

    #expect(result.runID == request.runID)
    #expect(result.messages.count == 2)
    #expect(result.turns.count == 1)
    #expect(result.turns.first?.providerResponseID == "response-1")
    #expect(result.totalReportedTokens == 15)
    #expect(
      events.map(eventKind) == [
        .runStarted,
        .messageAppended,
        .inferenceRequested,
        .inferenceStarted,
        .textDelta,
        .usage,
        .inferenceCompleted,
        .messageAppended,
        .runCompleted,
      ]
    )
  }

  @Test
  func toolResultAppearsInSecondInferenceRequestAndContentOrderIsPreserved() async throws {
    let call = ToolCall(
      id: ToolCallID(rawValue: "call-1"),
      name: "echo",
      arguments: ["value": .string("hello")]
    )
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [RuntimeTestFixture.model()],
      scripts: [
        .events(
          RuntimeTestFixture.toolEvents(
            [call],
            leadingText: "before",
            trailingText: "after"
          )
        ),
        .events(RuntimeTestFixture.textEvents("finished", responseID: "response-2")),
      ]
    )
    let executor = ScriptedToolExecutor(tools: [RuntimeTestFixture.tool()])
    let runtime = RuntimeTestFixture.runtime(provider: provider, executor: executor)

    let result = try await runtime.run(RuntimeTestFixture.request())
    let requests = await provider.requests()

    #expect(requests.count == 2)
    #expect(await executor.discoveryCount() == 2)
    let firstTurn = try #require(result.turns.first)
    #expect(
      firstTurn.assistantMessage.content == [
        .text("before"),
        .toolCall(call),
        .text("after"),
      ]
    )
    let toolMessage = try #require(requests[1].messages.last)
    guard case .toolResult(let toolResult) = toolMessage.content.first else {
      Issue.record("Expected the second inference request to end with a tool result.")
      return
    }
    #expect(toolMessage.role == .tool)
    #expect(toolResult.toolCallID == call.id)
    #expect(toolResult.status == .success)
  }

  @Test
  func mixedAllowedAndDeniedBatchExecutesOnlyAllowedCalls() async throws {
    let allowedCall = ToolCall(
      id: ToolCallID(rawValue: "allowed"),
      name: "echo",
      arguments: ["value": .string("safe")]
    )
    let deniedCall = ToolCall(
      id: ToolCallID(rawValue: "denied"),
      name: "inspect",
      arguments: ["secret": .string("must-not-enter-authorization")]
    )
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [RuntimeTestFixture.model()],
      scripts: [
        .events(RuntimeTestFixture.toolEvents([allowedCall, deniedCall])),
        .events(RuntimeTestFixture.textEvents("finished")),
      ]
    )
    let executor = ScriptedToolExecutor(
      tools: [RuntimeTestFixture.tool("echo"), RuntimeTestFixture.tool("inspect")]
    )
    let authorization = ScriptedAuthorizationProvider(
      mode: .decisions([.allow, .deny(reason: "Not granted.")])
    )
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: executor,
      authorization: authorization,
      journal: journal
    )

    let result = try await runtime.run(RuntimeTestFixture.request())
    let executedCalls = await executor.calls()
    let authorizationRequests = await authorization.requests()
    let events = await journal.events()

    #expect(executedCalls.map(\.id) == [allowedCall.id])
    #expect(authorizationRequests.map(\.toolCallID) == [allowedCall.id, deniedCall.id])
    #expect(authorizationRequests.allSatisfy { $0.details.isEmpty && $0.resource == nil })
    #expect(authorizationRequests.map(\.capability.rawValue) == ["tool.echo", "tool.inspect"])
    #expect(toolStartedIDs(in: events) == [allowedCall.id])
    #expect(toolFinishedIDs(in: events) == [allowedCall.id, deniedCall.id])
    let decisionIndices = events.indices.filter {
      if case .authorizationDecided = events[$0] { return true }
      return false
    }
    let firstToolStart = events.firstIndex {
      if case .toolStarted = $0 { return true }
      return false
    }
    #expect(decisionIndices.count == 2)
    if let firstToolStart {
      #expect(decisionIndices.allSatisfy { $0 < firstToolStart })
    } else {
      Issue.record("Expected the allowed tool to start.")
    }

    let deniedResult = try #require(
      result.turns.first?.toolResults.first { $0.toolCallID == deniedCall.id }
    )
    #expect(deniedResult.status == .failure)
    #expect(
      deniedResult.output
        == .object([
          "error": .string("authorization_denied"),
          "reason": .string("Not granted."),
        ])
    )
  }

  private func toolStartedIDs(in events: [AgentEvent]) -> [ToolCallID] {
    events.compactMap { event in
      if case .toolStarted(let call) = event { return call.id }
      return nil
    }
  }

  private func toolFinishedIDs(in events: [AgentEvent]) -> [ToolCallID] {
    events.compactMap { event in
      if case .toolFinished(let result) = event { return result.toolCallID }
      return nil
    }
  }

  private func eventKind(_ event: AgentEvent) -> AgentEventKind {
    switch event {
    case .runStarted: .runStarted
    case .messageAppended: .messageAppended
    case .contextCompactionStarted: .contextCompactionStarted
    case .contextCompacted: .contextCompacted
    case .inferenceRequested: .inferenceRequested
    case .inferenceEvent(.started): .inferenceStarted
    case .inferenceEvent(.textDelta): .textDelta
    case .inferenceEvent(.reasoningSummaryDelta): .reasoningSummary
    case .inferenceEvent(.toolCall): .toolCall
    case .inferenceEvent(.usage): .usage
    case .inferenceEvent(.completed): .inferenceCompleted
    case .authorizationRequested: .authorizationRequested
    case .authorizationDecided: .authorizationDecided
    case .toolStarted: .toolStarted
    case .toolFinished: .toolFinished
    case .runCompleted: .runCompleted
    case .runCancelled: .runCancelled
    case .runFailed: .runFailed
    }
  }

}
