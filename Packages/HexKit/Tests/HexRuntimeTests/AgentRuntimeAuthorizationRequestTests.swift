import HexCore
import HexRuntime
import Testing

@Suite("AgentRuntime authorization descriptions")
struct AgentRuntimeAuthorizationRequestTests {
  @Test
  func usesExactToolOwnedAuthorizationDescription() async throws {
    let runID = AgentRunID()
    let call = ToolCall(
      id: ToolCallID(rawValue: "write-call"),
      name: "write_file",
      arguments: ["path": .string("Sources/App.swift")]
    )
    let authorizationRequest = AuthorizationRequest(
      runID: runID,
      toolCallID: call.id,
      capability: CapabilityID(rawValue: "filesystem.write"),
      operation: "replace_file",
      resource: "/workspace/Sources/App.swift",
      details: ["workspaceRelativePath": .string("Sources/App.swift")],
      explanation: "Replace one file inside the selected workspace."
    )
    let executor = ScriptedToolExecutor(
      tools: [RuntimeTestFixture.tool("write_file")],
      authorizationBehaviors: [.request(authorizationRequest)]
    )
    let authorization = ScriptedAuthorizationProvider()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider(for: [call]),
      executor: executor,
      authorization: authorization
    )

    _ = try await runtime.run(RuntimeTestFixture.request(runID: runID))

    #expect(await authorization.requests() == [authorizationRequest])
    #expect(await executor.authorizationCalls() == [call])
  }

  @Test
  func rejectsMismatchedAuthorizationCorrelationBeforePromptOrExecution() async {
    let runID = AgentRunID()
    let call = ToolCall(
      id: ToolCallID(rawValue: "correlation-call"),
      name: "echo",
      arguments: [:]
    )
    let mismatched = AuthorizationRequest(
      runID: AgentRunID(),
      toolCallID: ToolCallID(rawValue: "other-call"),
      capability: CapabilityID(rawValue: "filesystem.read"),
      operation: "read",
      explanation: "Read one selected file."
    )
    let executor = ScriptedToolExecutor(
      tools: [RuntimeTestFixture.tool()],
      authorizationBehaviors: [.request(mismatched)]
    )
    let authorization = ScriptedAuthorizationProvider()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider(for: [call]),
      executor: executor,
      authorization: authorization
    )

    await expectAuthorizationFailure {
      try await runtime.run(RuntimeTestFixture.request(runID: runID))
    }
    #expect(await authorization.requests().isEmpty)
    #expect(await executor.calls().isEmpty)
  }

  @Test
  func rejectsDuplicateAuthorizationRequestIDsBeforePromptOrExecution() async {
    let runID = AgentRunID()
    let requestID = AuthorizationRequestID()
    let calls = [
      ToolCall(id: ToolCallID(rawValue: "first-call"), name: "echo", arguments: [:]),
      ToolCall(id: ToolCallID(rawValue: "second-call"), name: "inspect", arguments: [:]),
    ]
    let requests = calls.map { call in
      AuthorizationRequest(
        id: requestID,
        runID: runID,
        toolCallID: call.id,
        capability: CapabilityID(rawValue: "tool.\(call.name)"),
        operation: "execute",
        explanation: "Execute one test tool."
      )
    }
    let executor = ScriptedToolExecutor(
      tools: [RuntimeTestFixture.tool(), RuntimeTestFixture.tool("inspect")],
      authorizationBehaviors: requests.map(ToolAuthorizationBehavior.request)
    )
    let authorization = ScriptedAuthorizationProvider()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider(for: calls),
      executor: executor,
      authorization: authorization
    )

    await expectAuthorizationFailure {
      try await runtime.run(RuntimeTestFixture.request(runID: runID))
    }
    #expect(await authorization.requests().isEmpty)
    #expect(await executor.calls().isEmpty)
  }

  @Test
  func rejectsAuthorizationRequestIDReusedOnLaterTurn() async {
    let runID = AgentRunID()
    let requestID = AuthorizationRequestID()
    let firstCall = ToolCall(
      id: ToolCallID(rawValue: "first-turn-call"),
      name: "echo",
      arguments: [:]
    )
    let secondCall = ToolCall(
      id: ToolCallID(rawValue: "second-turn-call"),
      name: "inspect",
      arguments: [:]
    )
    let firstRequest = AuthorizationRequest(
      id: requestID,
      runID: runID,
      toolCallID: firstCall.id,
      capability: CapabilityID(rawValue: "tool.echo"),
      operation: "execute",
      explanation: "Execute the first test tool."
    )
    let reusedRequest = AuthorizationRequest(
      id: requestID,
      runID: runID,
      toolCallID: secondCall.id,
      capability: CapabilityID(rawValue: "tool.inspect"),
      operation: "execute",
      explanation: "Execute the second test tool."
    )
    let executor = ScriptedToolExecutor(
      tools: [RuntimeTestFixture.tool(), RuntimeTestFixture.tool("inspect")],
      authorizationBehaviors: [
        .request(firstRequest),
        .request(reusedRequest),
      ]
    )
    let authorization = ScriptedAuthorizationProvider()
    let runtime = RuntimeTestFixture.runtime(
      provider: ScriptedInferenceProvider(
        descriptor: RuntimeTestFixture.descriptor(),
        models: [RuntimeTestFixture.model()],
        scripts: [
          .events(RuntimeTestFixture.toolEvents([firstCall])),
          .events(RuntimeTestFixture.toolEvents([secondCall])),
        ]
      ),
      executor: executor,
      authorization: authorization
    )

    await expectAuthorizationFailure {
      try await runtime.run(RuntimeTestFixture.request(runID: runID))
    }

    #expect(await authorization.requests() == [firstRequest])
    #expect(await executor.authorizationCalls() == [firstCall, secondCall])
    #expect(await executor.calls() == [firstCall])
  }

  @Test
  func mapsDescriptionInfrastructureFailureWithoutPromptOrExecution() async {
    let call = ToolCall(
      id: ToolCallID(rawValue: "description-failure"),
      name: "echo",
      arguments: [:]
    )
    let executor = ScriptedToolExecutor(
      tools: [RuntimeTestFixture.tool()],
      authorizationBehaviors: [.throwing]
    )
    let authorization = ScriptedAuthorizationProvider()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider(for: [call]),
      executor: executor,
      authorization: authorization
    )

    await expectAuthorizationFailure {
      try await runtime.run(RuntimeTestFixture.request())
    }
    #expect(await authorization.requests().isEmpty)
    #expect(await executor.calls().isEmpty)
  }

  private func provider(for calls: [ToolCall]) -> ScriptedInferenceProvider {
    ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [RuntimeTestFixture.model()],
      scripts: [
        .events(RuntimeTestFixture.toolEvents(calls)),
        .events(RuntimeTestFixture.textEvents()),
      ]
    )
  }

  private func expectAuthorizationFailure(
    _ operation: () async throws -> AgentRunResult
  ) async {
    do {
      _ = try await operation()
      Issue.record("Expected authorizationFailure.")
    } catch AgentRuntimeError.authorizationFailure {
      // Expected fail-closed mapping.
    } catch {
      Issue.record("Expected authorizationFailure, received: \(error)")
    }
  }
}
