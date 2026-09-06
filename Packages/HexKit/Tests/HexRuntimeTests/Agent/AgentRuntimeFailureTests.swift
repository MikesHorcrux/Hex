import HexCore
import HexRuntime
import Testing

@Suite("AgentRuntime failure boundaries")
struct AgentRuntimeFailureTests {
  @Test
  func duplicateCallIDInOneBatchExecutesNothing() async {
    let first = ToolCall(
      id: ToolCallID(rawValue: "duplicate"),
      name: "echo",
      arguments: ["value": .integer(1)]
    )
    let second = ToolCall(
      id: first.id,
      name: "echo",
      arguments: ["value": .integer(2)]
    )
    let provider = provider(scripts: [.events(RuntimeTestFixture.toolEvents([first, second]))])
    let executor = ScriptedToolExecutor(tools: [RuntimeTestFixture.tool()])
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: executor,
      journal: journal
    )

    await expectProtocolViolation { _ = try await runtime.run(RuntimeTestFixture.request()) }

    #expect(await executor.calls().isEmpty)
    #expect(await journal.events().contains { if case .runFailed = $0 { true } else { false } })
  }

  @Test
  func duplicateCallIDOnLaterTurnNeverReexecutes() async {
    let call = ToolCall(
      id: ToolCallID(rawValue: "reused"),
      name: "echo",
      arguments: [:]
    )
    let provider = provider(
      scripts: [
        .events(RuntimeTestFixture.toolEvents([call])),
        .events(RuntimeTestFixture.toolEvents([call])),
      ]
    )
    let executor = ScriptedToolExecutor(tools: [RuntimeTestFixture.tool()])
    let runtime = RuntimeTestFixture.runtime(provider: provider, executor: executor)

    await expectProtocolViolation { _ = try await runtime.run(RuntimeTestFixture.request()) }

    #expect(await executor.calls().map(\.id) == [call.id])
  }

  @Test
  func journalFailureBeforeToolStartPreventsExecution() async {
    let call = ToolCall(
      id: ToolCallID(rawValue: "journal-before"),
      name: "echo",
      arguments: [:]
    )
    let provider = provider(scripts: [.events(RuntimeTestFixture.toolEvents([call]))])
    let executor = ScriptedToolExecutor(tools: [RuntimeTestFixture.tool()])
    let journal = RecordingEventJournal(failOn: .toolStarted)
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: executor,
      journal: journal
    )

    await expectJournalFailure { _ = try await runtime.run(RuntimeTestFixture.request()) }

    #expect(await executor.calls().isEmpty)
    let events = await journal.events()
    #expect(!events.contains { if case .toolStarted = $0 { true } else { false } })
    #expect(events.contains { if case .runFailed = $0 { true } else { false } })
  }

  @Test
  func journalFailureAfterOutcomeDoesNotRetryExecution() async {
    let call = ToolCall(
      id: ToolCallID(rawValue: "journal-after"),
      name: "echo",
      arguments: [:]
    )
    let provider = provider(scripts: [.events(RuntimeTestFixture.toolEvents([call]))])
    let executor = ScriptedToolExecutor(tools: [RuntimeTestFixture.tool()])
    let journal = RecordingEventJournal(failOn: .toolFinished)
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: executor,
      journal: journal
    )

    await expectJournalFailure { _ = try await runtime.run(RuntimeTestFixture.request()) }

    #expect(await executor.calls().map(\.id) == [call.id])
    let events = await journal.events()
    #expect(events.contains { if case .toolStarted = $0 { true } else { false } })
    #expect(!events.contains { if case .toolFinished = $0 { true } else { false } })
    #expect(events.contains { if case .runFailed = $0 { true } else { false } })
  }

  @Test
  func thrownToolLeavesUnmatchedStartAndTerminalFailure() async {
    let call = ToolCall(
      id: ToolCallID(rawValue: "tool-throws"),
      name: "echo",
      arguments: [:]
    )
    let provider = provider(scripts: [.events(RuntimeTestFixture.toolEvents([call]))])
    let executor = ScriptedToolExecutor(
      tools: [RuntimeTestFixture.tool()],
      behaviors: [.throwing]
    )
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: executor,
      journal: journal
    )

    await expectToolFailure { _ = try await runtime.run(RuntimeTestFixture.request()) }

    let events = await journal.events()
    #expect(events.contains { if case .toolStarted = $0 { true } else { false } })
    #expect(!events.contains { if case .toolFinished = $0 { true } else { false } })
    #expect(events.contains { if case .runFailed = $0 { true } else { false } })
    #expect(await executor.calls().count == 1)
  }

  @Test
  func mismatchedToolResultIDIsUncertainAndNotJournaledAsFinished() async {
    let call = ToolCall(
      id: ToolCallID(rawValue: "mismatch"),
      name: "echo",
      arguments: [:]
    )
    let provider = provider(scripts: [.events(RuntimeTestFixture.toolEvents([call]))])
    let executor = ScriptedToolExecutor(
      tools: [RuntimeTestFixture.tool()],
      behaviors: [.mismatchedID]
    )
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: executor,
      journal: journal
    )

    await expectToolFailure { _ = try await runtime.run(RuntimeTestFixture.request()) }

    let events = await journal.events()
    #expect(events.contains { if case .toolStarted = $0 { true } else { false } })
    #expect(!events.contains { if case .toolFinished = $0 { true } else { false } })
    #expect(await executor.calls().count == 1)
  }

  @Test
  func explicitToolFailureResultContinuesToNextInference() async throws {
    let call = ToolCall(
      id: ToolCallID(rawValue: "explicit-failure"),
      name: "echo",
      arguments: [:]
    )
    let provider = provider(
      scripts: [
        .events(RuntimeTestFixture.toolEvents([call])),
        .events(RuntimeTestFixture.textEvents("recovered")),
      ]
    )
    let executor = ScriptedToolExecutor(
      tools: [RuntimeTestFixture.tool()],
      behaviors: [.failureResult]
    )
    let runtime = RuntimeTestFixture.runtime(provider: provider, executor: executor)

    let result = try await runtime.run(RuntimeTestFixture.request())

    #expect(result.turns.count == 2)
    #expect(result.turns.first?.toolResults.first?.status == .failure)
    #expect(await provider.requests().count == 2)
    #expect(await executor.calls().count == 1)
  }

  @Test
  func terminalJournalFailureTakesPrecedenceOverRuntimeFailure() async {
    let provider = provider(
      scripts: [
        .events([
          .started(providerResponseID: nil),
          .completed(.stop),
        ])
      ]
    )
    let journal = RecordingEventJournal(failOn: .runFailed)
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: ScriptedToolExecutor(tools: []),
      journal: journal
    )

    await expectJournalFailure {
      _ = try await runtime.run(RuntimeTestFixture.request())
    }

    let events = await journal.events()
    #expect(!events.contains { if case .runFailed = $0 { true } else { false } })
    #expect(!events.contains { if case .runCompleted = $0 { true } else { false } })
  }

  @Test
  func providerCannotInjectRuntimeErrorOrPrivateDetail() async {
    let provider = provider(scripts: [.streamRuntimeFailure])
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: ScriptedToolExecutor(tools: []),
      journal: journal
    )

    do {
      _ = try await runtime.run(RuntimeTestFixture.request())
      Issue.record("Expected provider failure.")
    } catch AgentRuntimeError.providerFailure(let message, _) {
      #expect(!message.contains("private detail"))
    } catch {
      Issue.record("Expected providerFailure, received: \(error)")
    }

    let failures = await journal.events().compactMap { event in
      if case .runFailed(let failure) = event { return failure }
      return nil
    }
    #expect(failures.count == 1)
    #expect(failures.allSatisfy { !$0.message.contains("private detail") })
  }

  @Test
  func providerSafeFailureIsPreservedWhenOpeningTheStream() async {
    let runtime = RuntimeTestFixture.runtime(
      provider: provider(scripts: [.openingFailure]),
      executor: ScriptedToolExecutor(tools: [])
    )

    do {
      _ = try await runtime.run(RuntimeTestFixture.request())
      Issue.record("Expected provider failure.")
    } catch AgentRuntimeError.providerFailure(let message, let isRetryable) {
      #expect(message == "The test provider reported a safe failure.")
      #expect(isRetryable)
    } catch {
      Issue.record("Expected providerFailure, received: \(error)")
    }
  }

  @Test
  func providerSafeFailureIsPreservedInsideTheStream() async {
    let runtime = RuntimeTestFixture.runtime(
      provider: provider(scripts: [.streamFailure]),
      executor: ScriptedToolExecutor(tools: [])
    )

    do {
      _ = try await runtime.run(RuntimeTestFixture.request())
      Issue.record("Expected provider failure.")
    } catch AgentRuntimeError.providerFailure(let message, let isRetryable) {
      #expect(message == "The test provider reported a safe failure.")
      #expect(isRetryable)
    } catch {
      Issue.record("Expected providerFailure, received: \(error)")
    }
  }

  @Test
  func malformedProviderEventIsRejectedBeforeItBecomesDurable() async {
    let provider = provider(
      scripts: [
        .events([
          .started(providerResponseID: nil),
          .textDelta("complete"),
          .completed(.stop),
          .textDelta("must-not-be-journaled"),
        ])
      ]
    )
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: ScriptedToolExecutor(tools: []),
      journal: journal
    )

    await expectProtocolViolation {
      _ = try await runtime.run(RuntimeTestFixture.request())
    }

    let inferenceEvents = await journal.events().compactMap { event in
      if case .inferenceEvent(let inferenceEvent) = event { return inferenceEvent }
      return nil
    }
    #expect(
      inferenceEvents == [
        .started(providerResponseID: nil),
        .textDelta("complete"),
        .completed(.stop),
      ]
    )
  }

  @Test
  func durableFailureBecomesNonretryableAfterAnyToolStarts() async {
    let call = ToolCall(
      id: ToolCallID(rawValue: "retry-safety"),
      name: "echo",
      arguments: [:]
    )
    let postToolProvider = provider(
      scripts: [
        .events(RuntimeTestFixture.toolEvents([call])),
        .streamFailure,
      ]
    )
    let postToolJournal = RecordingEventJournal()
    let postToolRuntime = RuntimeTestFixture.runtime(
      provider: postToolProvider,
      executor: ScriptedToolExecutor(tools: [RuntimeTestFixture.tool()]),
      journal: postToolJournal
    )

    await expectProviderFailure {
      _ = try await postToolRuntime.run(RuntimeTestFixture.request())
    }

    let postToolFailures = await postToolJournal.events().compactMap { event in
      if case .runFailed(let failure) = event { return failure }
      return nil
    }
    #expect(postToolFailures.count == 1)
    #expect(postToolFailures.allSatisfy { !$0.isRetryable })

    let preToolProvider = provider(scripts: [.streamFailure])
    let preToolJournal = RecordingEventJournal()
    let preToolRuntime = RuntimeTestFixture.runtime(
      provider: preToolProvider,
      executor: ScriptedToolExecutor(tools: []),
      journal: preToolJournal
    )

    await expectProviderFailure {
      _ = try await preToolRuntime.run(RuntimeTestFixture.request())
    }

    let preToolFailures = await preToolJournal.events().compactMap { event in
      if case .runFailed(let failure) = event { return failure }
      return nil
    }
    #expect(preToolFailures.count == 1)
    #expect(preToolFailures.allSatisfy { $0.isRetryable })
  }

  private func provider(scripts: [InferenceScript]) -> ScriptedInferenceProvider {
    ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [RuntimeTestFixture.model()],
      scripts: scripts
    )
  }

  private func expectProtocolViolation(
    _ operation: @escaping @Sendable () async throws -> Void
  ) async {
    await expectError(operation) { error in
      if case .protocolViolation = error { return true }
      return false
    }
  }

  private func expectJournalFailure(
    _ operation: @escaping @Sendable () async throws -> Void
  ) async {
    await expectError(operation) { error in
      if case .journalFailure = error { return true }
      return false
    }
  }

  private func expectToolFailure(
    _ operation: @escaping @Sendable () async throws -> Void
  ) async {
    await expectError(operation) { error in
      if case .toolExecutionFailure = error { return true }
      return false
    }
  }

  private func expectProviderFailure(
    _ operation: @escaping @Sendable () async throws -> Void
  ) async {
    await expectError(operation) { error in
      if case .providerFailure = error { return true }
      return false
    }
  }

  private func expectError(
    _ operation: @escaping @Sendable () async throws -> Void,
    matching predicate: (AgentRuntimeError) -> Bool
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
}
