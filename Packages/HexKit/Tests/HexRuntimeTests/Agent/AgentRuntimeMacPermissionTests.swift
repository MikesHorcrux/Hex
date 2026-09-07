import HexCore
import HexRuntime
import Testing

@Suite("Mac permission loss stops the runtime")
struct AgentRuntimeMacPermissionTests {
  @Test(arguments: [
    "accessibility_permission_required", "file_access_denied", "screen_permissions_required",
    "screen_permissions_unverified",
  ])
  func permissionBlockerPreservesReceiptWithoutRetryingOrExecutingSiblings(_ code: String)
    async throws
  {
    let first = ToolCall(name: "echo", arguments: [:])
    let second = ToolCall(name: "echo", arguments: [:])
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(), models: [RuntimeTestFixture.model()],
      scripts: [
        .events(RuntimeTestFixture.toolEvents([first, second])),
        .events(RuntimeTestFixture.textEvents()),
      ])
    let result = ToolResult(
      toolCallID: first.id, status: .failure,
      output: .object(["error": .string(code)]), requiresUserAttention: true)
    let executor = ScriptedToolExecutor(
      tools: [RuntimeTestFixture.tool()], behaviors: [.result(result)])
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider, executor: executor, journal: journal)
    await #expect(throws: AgentRuntimeError.self) {
      try await runtime.run(RuntimeTestFixture.request())
    }
    #expect(await executor.calls().map(\.id) == [first.id])
    #expect(await provider.requests().count == 1)
    let events = await journal.events()
    #expect(events.contains(.toolFinished(result)))
    let failure = try #require(
      events.compactMap { event -> AgentFailure? in
        if case .runFailed(let failure) = event { return failure }
        return nil
      }.last)
    #expect(failure.message.contains("Mac access"))
    #expect(failure.message.contains("will not retry automatically"))
  }
}
