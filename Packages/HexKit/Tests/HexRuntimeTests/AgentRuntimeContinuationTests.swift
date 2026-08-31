import HexCore
import HexRuntime
import Testing

@Suite("AgentRuntime provider continuation")
struct AgentRuntimeContinuationTests {
  @Test
  func advancesProviderResponseIdentityAcrossToolTurns() async throws {
    let call = ToolCall(
      id: ToolCallID(rawValue: "continuation-call"),
      name: "echo",
      arguments: [:]
    )
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [RuntimeTestFixture.model()],
      scripts: [
        .events(RuntimeTestFixture.toolEvents([call])),
        .events(RuntimeTestFixture.textEvents(responseID: "final-response")),
      ]
    )
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: ScriptedToolExecutor(tools: [RuntimeTestFixture.tool()])
    )

    _ = try await runtime.run(RuntimeTestFixture.request())

    let requests = await provider.requests()
    #expect(requests.count == 2)
    #expect(requests[0].previousProviderResponseID == nil)
    #expect(requests[1].previousProviderResponseID == "tool-response")
  }
}
