import HexCore
import HexRuntime
import Testing

@Suite("Completed operation recovery")
struct AgentRuntimeCompletedOperationRecoveryTests {
  @Test
  func knownReplayRejectionAllowsTheModelToObserveAndFinish() async throws {
    let duplicate = ToolCall(name: "echo", arguments: [:])
    let observation = ToolCall(name: "echo", arguments: ["value": .string("observe")])
    let rejected = ToolResult(
      toolCallID: duplicate.id, status: .failure,
      output: .object(["error": .string("task_operation_already_dispatched")]),
      executionOutcome: .completed)
    let observed = ToolResult(
      toolCallID: observation.id, status: .success, output: .string("Preview verified"))
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(), models: [RuntimeTestFixture.model()],
      scripts: [
        .events(RuntimeTestFixture.toolEvents([duplicate])),
        .events(RuntimeTestFixture.toolEvents([observation])),
        .events(RuntimeTestFixture.textEvents()),
      ])
    let executor = ScriptedToolExecutor(
      tools: [RuntimeTestFixture.tool()], behaviors: [.result(rejected), .result(observed)])
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider, executor: executor, journal: journal)
    _ = try await runtime.run(RuntimeTestFixture.request())
    #expect(await provider.requests().count == 3)
    #expect(await executor.calls().map(\.id) == [duplicate.id, observation.id])
    #expect(await journal.events().contains(.toolFinished(rejected)))
    #expect(await journal.events().contains(.toolFinished(observed)))
  }
}
