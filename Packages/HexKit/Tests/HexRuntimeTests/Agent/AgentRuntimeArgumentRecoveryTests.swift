import HexCore
import HexRuntime
import Testing

@Suite("Malformed arguments recover before authorization")
struct AgentRuntimeArgumentRecoveryTests {
  @Test
  func malformedCallIsNotDispatchedAndModelCanCorrectIt() async throws {
    let invalid = ToolCall(name: "echo", arguments: ["observation_id": .string("?")])
    let sibling = ToolCall(name: "echo", arguments: [:])
    let corrected = ToolCall(name: "echo", arguments: [:])
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(), models: [RuntimeTestFixture.model()],
      scripts: [
        .events(RuntimeTestFixture.toolEvents([invalid, sibling])),
        .events(RuntimeTestFixture.toolEvents([corrected])),
        .events(RuntimeTestFixture.textEvents()),
      ])
    let executor = ScriptedToolExecutor(
      tools: [RuntimeTestFixture.tool()], authorizationBehaviors: [.invalidArguments])
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider, executor: executor, journal: journal)
    _ = try await runtime.run(RuntimeTestFixture.request())
    #expect(await executor.calls().map(\.id) == [sibling.id, corrected.id])
    #expect(await provider.requests().count == 3)
    let events = await journal.events()
    #expect(!events.contains(.toolStarted(invalid)))
    #expect(
      !events.contains { event in
        if case .authorizationRequested(let request) = event {
          return request.toolCallID == invalid.id
        }
        return false
      })
    let rejected = try #require(
      events.compactMap { event -> ToolResult? in
        if case .toolFinished(let result) = event, result.toolCallID == invalid.id { return result }
        return nil
      }.first)
    #expect(rejected.status == .failure)
    #expect(rejected.notExecutedReason != nil)
    #expect(
      rejected.output
        == .object([
          "error": .string("invalid_tool_arguments"), "dispatched": .boolean(false),
          "recovery": .string("Observe again and use the returned ID."),
        ]))
  }

  @Test
  func unknownAuthorizationFailureStillStopsBeforeDispatch() async throws {
    let call = ToolCall(name: "echo", arguments: [:])
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(), models: [RuntimeTestFixture.model()],
      scripts: [.events(RuntimeTestFixture.toolEvents([call]))])
    let executor = ScriptedToolExecutor(
      tools: [RuntimeTestFixture.tool()], authorizationBehaviors: [.throwing])
    let runtime = RuntimeTestFixture.runtime(provider: provider, executor: executor)
    await #expect(throws: AgentRuntimeError.self) {
      try await runtime.run(RuntimeTestFixture.request())
    }
    #expect(await executor.calls().isEmpty)
  }
}
