import HexCore
import HexRuntime
import Testing

@Suite("AgentRuntime tool discovery follows explicit run choice")
struct AgentRuntimeToolDiscoveryChoiceTests {
  @Test
  func noneCompletesWithoutDiscoveringOrAdvertisingBrokenTools() async throws {
    let provider = provider(scripts: [.events(RuntimeTestFixture.textEvents("Hello."))])
    let executor = ScriptedToolExecutor(
      tools: [RuntimeTestFixture.tool()], discoveryFails: true)
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider, executor: executor, journal: journal)

    let result = try await runtime.run(RuntimeTestFixture.request(toolChoice: .none))

    #expect(result.turns.count == 1)
    #expect(result.toolCallCount == 0)
    #expect(await executor.discoveryCount() == 0)
    let inference = try #require(await provider.requests().first)
    #expect(inference.tools.isEmpty)
    #expect(inference.toolChoice == .none)
    let events = await journal.events()
    let durableRequests = events.compactMap { event -> InferenceRequest? in
      if case .inferenceRequested(let request) = event { return request }
      return nil
    }
    #expect(durableRequests == [inference])
    #expect(events.last == .runCompleted)
  }

  @Test
  func noneRejectsUnsolicitedCallBeforeAuthorizationOrExecution() async throws {
    let call = ToolCall(id: ToolCallID(rawValue: "unsolicited"), name: "echo", arguments: [:])
    let provider = provider(scripts: [.events(RuntimeTestFixture.toolEvents([call]))])
    let executor = ScriptedToolExecutor(
      tools: [RuntimeTestFixture.tool()], discoveryFails: true)
    let authorization = ScriptedAuthorizationProvider()
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider, executor: executor, authorization: authorization, journal: journal)

    do {
      _ = try await runtime.run(RuntimeTestFixture.request(toolChoice: .none))
      Issue.record("A no-tools request must reject a provider's unsolicited call.")
    } catch let error as AgentRuntimeError {
      guard case .protocolViolation = error else {
        Issue.record("Expected a stream protocol refusal, received \(error).")
        return
      }
    }

    #expect(await executor.discoveryCount() == 0)
    #expect(await provider.requests().count == 1)
    #expect(await executor.authorizationCalls().isEmpty)
    #expect(await authorization.requests().isEmpty)
    #expect(await executor.calls().isEmpty)
    let events = await journal.events()
    #expect(
      !events.contains {
        switch $0 {
        case .authorizationRequested, .authorizationDecided, .toolStarted, .toolFinished: true
        default: false
        }
      })
    #expect(events.contains { if case .runFailed = $0 { true } else { false } })
  }

  @Test(arguments: [ToolChoice.automatic, .required, .named("echo")])
  func toolEnabledChoicesStillDiscoverAndFailBeforeInference(choice: ToolChoice) async throws {
    let provider = provider(scripts: [.events(RuntimeTestFixture.textEvents("Must not run."))])
    let executor = ScriptedToolExecutor(
      tools: [RuntimeTestFixture.tool()], discoveryFails: true)
    let authorization = ScriptedAuthorizationProvider()
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider, executor: executor, authorization: authorization, journal: journal)

    do {
      _ = try await runtime.run(RuntimeTestFixture.request(toolChoice: choice))
      Issue.record("A tool-enabled run must not bypass a failed discovery boundary.")
    } catch let error as AgentRuntimeError {
      #expect(error == .toolExecutionFailure("Tool discovery failed."))
    }

    #expect(await executor.discoveryCount() == 1)
    #expect(await provider.requests().isEmpty)
    #expect(await executor.authorizationCalls().isEmpty)
    #expect(await authorization.requests().isEmpty)
    #expect(await executor.calls().isEmpty)
    #expect(
      !((await journal.events()).contains {
        if case .inferenceRequested = $0 { true } else { false }
      }))
  }

  @Test
  func namedContinuationKeepsItsExistingSnapshotWhileChangingChoiceToNone() async throws {
    let call = ToolCall(id: ToolCallID(rawValue: "named-first"), name: "echo", arguments: [:])
    let tools = [RuntimeTestFixture.tool(), RuntimeTestFixture.tool("inspect")]
    let provider = provider(scripts: [
      .events(RuntimeTestFixture.toolEvents([call])),
      .events(RuntimeTestFixture.textEvents("Finished.")),
    ])
    let executor = ScriptedToolExecutor(tools: tools)
    let runtime = RuntimeTestFixture.runtime(provider: provider, executor: executor)

    let result = try await runtime.run(RuntimeTestFixture.request(toolChoice: .named("echo")))

    #expect(result.turns.count == 2)
    #expect(await executor.discoveryCount() == 1)
    #expect(await executor.calls() == [call])
    let requests = await provider.requests()
    #expect(requests.map(\.toolChoice) == [.named("echo"), .none])
    #expect(requests.map(\.tools) == [tools, tools])
  }

  private func provider(scripts: [InferenceScript]) -> ScriptedInferenceProvider {
    ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(), models: [RuntimeTestFixture.model()],
      scripts: scripts)
  }
}
