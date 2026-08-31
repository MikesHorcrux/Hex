import Foundation
import HexCore
import Testing
@testable import HexRuntime

@Suite("AgentRuntime validation")
struct AgentRuntimeValidationTests {
  @Test
  func requiresProviderAndModelCapabilityIntersection() async {
    let model = RuntimeTestFixture.model()
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(capabilities: [.textInput]),
      models: [model],
      scripts: []
    )
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: ScriptedToolExecutor(tools: [])
    )

    await expectUnsupportedCapability(.streaming) {
      _ = try await runtime.run(RuntimeTestFixture.request())
    }
  }

  @Test
  func imageInputRequiresCapabilityFromBothProviderAndModel() async throws {
    let imageURL = try #require(URL(string: "https://example.com/image.png"))
    let message = Message(
      role: .user,
      content: [.image(ImageContent(sourceURL: imageURL, mediaType: "image/png"))]
    )
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [RuntimeTestFixture.model()],
      scripts: []
    )
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: ScriptedToolExecutor(tools: [])
    )

    await expectUnsupportedCapability(.imageInput) {
      _ = try await runtime.run(RuntimeTestFixture.request(messages: [message]))
    }
  }

  @Test
  func rejectsModelFromDifferentProviderAndExcessOutputRequest() async {
    let wrongProvider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [RuntimeTestFixture.model(providerID: ProviderID(rawValue: "other"))],
      scripts: []
    )
    let wrongProviderRuntime = RuntimeTestFixture.runtime(
      provider: wrongProvider,
      executor: ScriptedToolExecutor(tools: [])
    )
    await expectError(
      matching: { if case .providerFailure = $0 { true } else { false } },
      operation: { _ = try await wrongProviderRuntime.run(RuntimeTestFixture.request()) }
    )

    let limitedProvider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [RuntimeTestFixture.model(maxOutputTokens: 10)],
      scripts: []
    )
    let limitedRuntime = RuntimeTestFixture.runtime(
      provider: limitedProvider,
      executor: ScriptedToolExecutor(tools: [])
    )
    await expectError(
      matching: { if case .invalidRequest = $0 { true } else { false } },
      operation: {
        _ = try await limitedRuntime.run(
          RuntimeTestFixture.request(options: InferenceOptions(maxOutputTokens: 11))
        )
      }
    )
  }

  @Test
  func validatesAbsoluteWorkingDirectoryAndPreservesItForExecution() async throws {
    let invalidProvider = provider(scripts: [])
    let invalidRuntime = RuntimeTestFixture.runtime(
      provider: invalidProvider,
      executor: ScriptedToolExecutor(tools: [])
    )
    let invalidURL = try #require(URL(string: "https://example.com/not-a-directory"))
    await expectError(
      matching: { if case .invalidRequest = $0 { true } else { false } },
      operation: {
        _ = try await invalidRuntime.run(
          RuntimeTestFixture.request(workingDirectory: invalidURL)
        )
      }
    )

    let call = ToolCall(
      id: ToolCallID(rawValue: "working-directory"),
      name: "echo",
      arguments: [:]
    )
    let validProvider = provider(
      scripts: [
        .events(RuntimeTestFixture.toolEvents([call])),
        .events(RuntimeTestFixture.textEvents()),
      ]
    )
    let executor = ScriptedToolExecutor(tools: [RuntimeTestFixture.tool()])
    let runtime = RuntimeTestFixture.runtime(provider: validProvider, executor: executor)
    let directory = URL(fileURLWithPath: "/tmp/hex-runtime-test", isDirectory: true)

    _ = try await runtime.run(RuntimeTestFixture.request(workingDirectory: directory))

    #expect(await executor.contexts().first?.workingDirectory == directory)
  }

  @Test
  func rejectsDuplicateActiveRunIDAndLaterReuseAfterDurableStart() async {
    let runID = AgentRunID()
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [RuntimeTestFixture.model()],
      scripts: [.suspend]
    )
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: ScriptedToolExecutor(tools: [])
    )
    let request = RuntimeTestFixture.request(runID: runID)
    let first = Task { try await runtime.run(request) }
    await waitUntil { await provider.requests().count == 1 }

    do {
      _ = try await runtime.run(request)
      Issue.record("Expected duplicate active run rejection.")
    } catch AgentRuntimeError.duplicateRun(let duplicateID) {
      #expect(duplicateID == runID)
    } catch {
      Issue.record("Expected duplicateRun, received: \(error)")
    }

    first.cancel()
    do {
      _ = try await first.value
      Issue.record("Expected first run cancellation.")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("Expected CancellationError, received: \(error)")
    }

    do {
      _ = try await runtime.run(request)
      Issue.record("Expected durable run ID reuse rejection.")
    } catch AgentRuntimeError.duplicateRun(let duplicateID) {
      #expect(duplicateID == runID)
    } catch {
      Issue.record("Expected duplicateRun, received: \(error)")
    }
  }

  @Test
  func validationFailureDoesNotConsumeRunID() async throws {
    let runID = AgentRunID()
    let provider = provider(scripts: [.events(RuntimeTestFixture.textEvents())])
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: ScriptedToolExecutor(tools: [])
    )

    await expectError(
      matching: { if case .invalidRequest = $0 { true } else { false } },
      operation: {
        _ = try await runtime.run(
          RuntimeTestFixture.request(runID: runID, messages: [])
        )
      }
    )

    let result = try await runtime.run(RuntimeTestFixture.request(runID: runID))
    #expect(result.runID == runID)
  }

  @Test
  func rejectsDuplicateToolNamesAndUnavailableNamedChoice() async {
    let duplicateProvider = provider(scripts: [])
    let duplicateRuntime = RuntimeTestFixture.runtime(
      provider: duplicateProvider,
      executor: ScriptedToolExecutor(
        tools: [RuntimeTestFixture.tool("same"), RuntimeTestFixture.tool("same")]
      )
    )
    await expectError(
      matching: { if case .protocolViolation = $0 { true } else { false } },
      operation: { _ = try await duplicateRuntime.run(RuntimeTestFixture.request()) }
    )

    let namedProvider = provider(scripts: [])
    let namedRuntime = RuntimeTestFixture.runtime(
      provider: namedProvider,
      executor: ScriptedToolExecutor(tools: [RuntimeTestFixture.tool("available")])
    )
    await expectError(
      matching: { if case .invalidRequest = $0 { true } else { false } },
      operation: {
        _ = try await namedRuntime.run(
          RuntimeTestFixture.request(toolChoice: .named("missing"))
        )
      }
    )
  }

  @Test
  func multipleToolCallsRequireParallelCapabilityFromProviderAndModel() async {
    let calls = [
      ToolCall(id: ToolCallID(rawValue: "first"), name: "echo", arguments: [:]),
      ToolCall(id: ToolCallID(rawValue: "second"), name: "echo", arguments: [:]),
    ]
    let capabilities: Set<InferenceCapability> = [
      .textInput,
      .streaming,
      .toolCalling,
    ]
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(capabilities: capabilities),
      models: [RuntimeTestFixture.model(capabilities: capabilities)],
      scripts: [.events(RuntimeTestFixture.toolEvents(calls))]
    )
    let authorization = ScriptedAuthorizationProvider()
    let executor = ScriptedToolExecutor(tools: [RuntimeTestFixture.tool()])
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: executor,
      authorization: authorization,
      journal: journal
    )

    await expectUnsupportedCapability(.parallelToolCalling) {
      _ = try await runtime.run(RuntimeTestFixture.request())
    }

    #expect(await authorization.requests().isEmpty)
    #expect(await executor.calls().isEmpty)
    let inferenceEvents = await journal.events().compactMap { event in
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
  }

  @Test
  func providerMustHonorRequiredAndNamedToolChoices() async {
    let requiredProvider = provider(
      scripts: [.events(RuntimeTestFixture.textEvents("ignored requirement"))]
    )
    let requiredExecutor = ScriptedToolExecutor(tools: [RuntimeTestFixture.tool()])
    let requiredRuntime = RuntimeTestFixture.runtime(
      provider: requiredProvider,
      executor: requiredExecutor
    )
    await expectError(
      matching: { if case .protocolViolation = $0 { true } else { false } },
      operation: {
        _ = try await requiredRuntime.run(
          RuntimeTestFixture.request(toolChoice: .required)
        )
      }
    )

    let wrongCall = ToolCall(
      id: ToolCallID(rawValue: "wrong-named-tool"),
      name: "inspect",
      arguments: [:]
    )
    let namedProvider = provider(
      scripts: [.events(RuntimeTestFixture.toolEvents([wrongCall]))]
    )
    let namedExecutor = ScriptedToolExecutor(
      tools: [RuntimeTestFixture.tool("echo"), RuntimeTestFixture.tool("inspect")]
    )
    let namedRuntime = RuntimeTestFixture.runtime(
      provider: namedProvider,
      executor: namedExecutor
    )
    await expectError(
      matching: { if case .protocolViolation = $0 { true } else { false } },
      operation: {
        _ = try await namedRuntime.run(
          RuntimeTestFixture.request(toolChoice: .named("echo"))
        )
      }
    )

    #expect(await requiredExecutor.calls().isEmpty)
    #expect(await namedExecutor.calls().isEmpty)
  }

  @Test
  func forcedToolChoiceBecomesAutomaticAfterFirstAcceptedBatch() async throws {
    let requiredCall = ToolCall(
      id: ToolCallID(rawValue: "required-once"),
      name: "echo",
      arguments: [:]
    )
    let requiredProvider = provider(
      scripts: [
        .events(RuntimeTestFixture.toolEvents([requiredCall])),
        .events(RuntimeTestFixture.textEvents("required complete")),
      ]
    )
    let requiredRuntime = RuntimeTestFixture.runtime(
      provider: requiredProvider,
      executor: ScriptedToolExecutor(tools: [RuntimeTestFixture.tool()])
    )

    let requiredResult = try await requiredRuntime.run(
      RuntimeTestFixture.request(toolChoice: .required)
    )

    #expect(requiredResult.turns.count == 2)
    #expect(await requiredProvider.requests().map(\.toolChoice) == [.required, .automatic])

    let namedCall = ToolCall(
      id: ToolCallID(rawValue: "named-once"),
      name: "echo",
      arguments: [:]
    )
    let namedProvider = provider(
      scripts: [
        .events(RuntimeTestFixture.toolEvents([namedCall])),
        .events(RuntimeTestFixture.textEvents("named complete")),
      ]
    )
    let namedRuntime = RuntimeTestFixture.runtime(
      provider: namedProvider,
      executor: ScriptedToolExecutor(
        tools: [RuntimeTestFixture.tool("echo"), RuntimeTestFixture.tool("inspect")]
      )
    )

    let namedResult = try await namedRuntime.run(
      RuntimeTestFixture.request(toolChoice: .named("echo"))
    )

    #expect(namedResult.turns.count == 2)
    #expect(
      await namedProvider.requests().map(\.toolChoice)
        == [.named("echo"), .automatic]
    )
  }

  @Test
  func acceptsResolvedInitialToolHistory() async throws {
    let call = ToolCall(
      id: ToolCallID(rawValue: "prior-call"),
      name: "echo",
      arguments: ["value": .string("input")]
    )
    let result = ToolResult(
      toolCallID: call.id,
      status: .success,
      output: .string("output")
    )
    let messages = [
      Message(role: .assistant, content: [.text("calling"), .toolCall(call)]),
      Message(role: .tool, content: [.toolResult(result)]),
    ]
    let provider = provider(scripts: [.events(RuntimeTestFixture.textEvents())])
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: ScriptedToolExecutor(tools: [])
    )

    let runResult = try await runtime.run(
      RuntimeTestFixture.request(messages: messages, toolChoice: .none)
    )

    #expect(runResult.messages.starts(with: messages))
  }

  @Test
  func rejectsMalformedInitialToolHistoryBeforeLifecycleStarts() async {
    let call = ToolCall(
      id: ToolCallID(rawValue: "history-call"),
      name: "echo",
      arguments: [:]
    )
    let result = ToolResult(toolCallID: call.id, status: .success, output: .null)
    let invalidHistories: [[Message]] = [
      [Message(role: .tool, content: [.toolResult(result)])],
      [
        Message(role: .tool, content: [.toolResult(result)]),
        Message(role: .assistant, content: [.toolCall(call)]),
      ],
      [Message(role: .user, content: [.toolCall(call)])],
      [
        Message(role: .assistant, content: [.toolCall(call)]),
        Message(role: .assistant, content: [.toolResult(result)]),
      ],
      [
        Message(role: .assistant, content: [.toolCall(call)]),
        Message(role: .tool, content: [.toolResult(result)]),
        Message(role: .tool, content: [.toolResult(result)]),
      ],
      [Message(role: .assistant, content: [.toolCall(call)])],
      [
        Message(role: .assistant, content: [.toolCall(call)]),
        Message(
          role: .tool,
          content: [
            .toolResult(
              ToolResult(
                toolCallID: ToolCallID(rawValue: " \n"),
                status: .failure,
                output: .null
              )
            )
          ]
        ),
      ],
      [
        Message(role: .assistant, content: [.toolCall(call)]),
        Message(role: .tool, content: [.toolResult(result)]),
        Message(role: .assistant, content: [.toolCall(call)]),
      ],
      [
        Message(
          role: .assistant,
          content: [
            .toolCall(
              ToolCall(id: ToolCallID(rawValue: "   "), name: "echo", arguments: [:])
            )
          ]
        )
      ],
      [
        Message(
          role: .assistant,
          content: [
            .toolCall(
              ToolCall(id: ToolCallID(rawValue: "blank-name"), name: " \n", arguments: [:])
            )
          ]
        )
      ],
      [Message(role: .tool, content: [.text("wrong tool message content")])],
    ]

    for messages in invalidHistories {
      let journal = RecordingEventJournal()
      let runtime = RuntimeTestFixture.runtime(
        provider: provider(scripts: []),
        executor: ScriptedToolExecutor(tools: []),
        journal: journal
      )
      await expectError(
        matching: { if case .invalidRequest = $0 { true } else { false } },
        operation: {
          _ = try await runtime.run(RuntimeTestFixture.request(messages: messages))
        }
      )
      #expect(await journal.events().isEmpty)
    }
  }

  @Test
  func runtimeValueTypesRoundTripAsCodableAndRemainSendable() throws {
    let request = RuntimeTestFixture.request()
    let turn = InferenceTurn(
      number: 1,
      requestID: InferenceRequestID(),
      providerResponseID: "response",
      assistantMessage: Message(role: .assistant, content: [.text("done")]),
      toolResults: [],
      usage: InferenceUsage(inputTokens: 1, outputTokens: 1),
      stopReason: .stop
    )
    let result = AgentRunResult(
      runID: request.runID,
      messages: request.initialMessages + [turn.assistantMessage],
      turns: [turn],
      toolCallCount: 0,
      totalReportedTokens: 2
    )

    #expect(try roundTrip(request) == request)
    #expect(try roundTrip(AgentRuntimeConfiguration()) == AgentRuntimeConfiguration())
    #expect(try roundTrip(turn) == turn)
    #expect(try roundTrip(result) == result)
    #expect(
      try roundTrip(AgentRuntimeError.budgetExceeded("bounded"))
        == .budgetExceeded("bounded")
    )
    requireSendable(AgentRunRequest.self)
    requireSendable(AgentRunResult.self)
    requireSendable(InferenceTurn.self)
    requireSendable(AgentRuntimeError.self)
    #expect(HexRuntimeModule.name == "HexRuntime")
  }

  @Test
  func rejectsUnserializableInitialMessagesBeforeStartingRun() async {
    let call = ToolCall(
      id: ToolCallID(rawValue: "noncanonical-number"),
      name: "echo",
      arguments: [:]
    )
    let message = Message(
      role: .assistant,
      content: [.toolCall(call)]
    )
    let resultMessage = Message(
      role: .tool,
      content: [
        .toolResult(
          ToolResult(
            toolCallID: call.id,
            status: .success,
            output: .number(42.0)
          )
        )
      ]
    )
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider(scripts: []),
      executor: ScriptedToolExecutor(tools: []),
      journal: journal
    )

    await expectError(
      matching: { if case .invalidRequest = $0 { true } else { false } },
      operation: {
        _ = try await runtime.run(
          RuntimeTestFixture.request(messages: [message, resultMessage])
        )
      }
    )

    #expect(await journal.events().isEmpty)
  }

  private func provider(scripts: [InferenceScript]) -> ScriptedInferenceProvider {
    ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [RuntimeTestFixture.model()],
      scripts: scripts
    )
  }

  private func expectUnsupportedCapability(
    _ capability: InferenceCapability,
    operation: @escaping @Sendable () async throws -> Void
  ) async {
    await expectError(
      matching: {
        if case .unsupportedCapability(let received) = $0 { return received == capability }
        return false
      },
      operation: operation
    )
  }

  private func expectError(
    matching predicate: (AgentRuntimeError) -> Bool,
    operation: @escaping @Sendable () async throws -> Void
  ) async {
    do {
      try await operation()
      Issue.record("Expected AgentRuntimeError.")
    } catch let error as AgentRuntimeError {
      #expect(predicate(error))
    } catch {
      Issue.record("Expected AgentRuntimeError, received: \(error)")
    }
  }

  private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async {
    for _ in 0..<10_000 {
      if await condition() { return }
      await Task.yield()
    }
    Issue.record("Timed out waiting for the scripted boundary.")
  }

  private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Value.self, from: data)
  }

  private func requireSendable<Value: Sendable>(_: Value.Type) {}
}
