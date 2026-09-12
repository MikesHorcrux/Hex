import HexCore
import HexRuntime
import Testing

@Suite("AgentRuntime cancellation")
struct AgentRuntimeCancellationTests {
  @Test(arguments: [false, true])
  func boundaryStopCancelsIdleInferenceWithoutWaitingForProviderCompletion(opening: Bool) async {
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(), models: [RuntimeTestFixture.model()],
      scripts: [opening ? .suspendOpening : .suspend])
    let journal = RecordingEventJournal()
    let executor = ScriptedToolExecutor(tools: [])
    let runtime = RuntimeTestFixture.runtime(
      provider: provider, executor: executor, journal: journal)
    let request = RuntimeTestFixture.request()
    let task = Task { try await runtime.run(request) }
    await waitUntil { await provider.requests().count == 1 }
    await runtime.stopAtBoundary(request.runID)
    for _ in 0..<200 {
      if await journal.events().contains(where: {
        if case .runCancelled = $0 { true } else { false }
      }) {
        break
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    let events = await journal.events()
    #expect(events.contains { if case .runCancelled = $0 { true } else { false } })
    #expect(!events.contains { if case .runFailed = $0 { true } else { false } })
    #expect(await executor.calls().isEmpty)
    task.cancel()  // Bound cleanup even when this regression fails.
    await expectCancellation(task)
  }

  @Test
  func boundaryStopWaitsForDispatchedToolReceiptBeforeStopping() async {
    let call = ToolCall(id: ToolCallID(rawValue: "boundary-receipt"), name: "echo", arguments: [:])
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(), models: [RuntimeTestFixture.model()],
      scripts: [.events(RuntimeTestFixture.toolEvents([call]))])
    let journal = RecordingEventJournal(blockOn: .toolFinished)
    let executor = ScriptedToolExecutor(tools: [RuntimeTestFixture.tool()])
    let runtime = RuntimeTestFixture.runtime(
      provider: provider, executor: executor, journal: journal)
    let request = RuntimeTestFixture.request()
    let task = Task { try await runtime.run(request) }
    await waitUntil { await journal.isBlocked() }
    await runtime.stopAtBoundary(request.runID)
    #expect(
      !(await journal.events()).contains { if case .runCancelled = $0 { true } else { false } })
    await journal.releaseBlockedAppend()
    await expectCancellation(task)
    let events = await journal.events()
    let finished = events.firstIndex { if case .toolFinished = $0 { true } else { false } }
    let cancelled = events.firstIndex { if case .runCancelled = $0 { true } else { false } }
    #expect(finished != nil && cancelled != nil)
    if let finished, let cancelled { #expect(finished < cancelled) }
    #expect(await executor.calls().count == 1)
  }

  @Test
  func cancellationDuringInferenceJournalsRunCancelled() async {
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [RuntimeTestFixture.model()],
      scripts: [.suspend]
    )
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: ScriptedToolExecutor(tools: []),
      journal: journal
    )
    let task = Task { try await runtime.run(RuntimeTestFixture.request()) }
    await waitUntil { await provider.requests().count == 1 }

    task.cancel()
    await expectCancellation(task)

    let events = await journal.events()
    #expect(events.contains { if case .runCancelled = $0 { true } else { false } })
    #expect(!events.contains { if case .runFailed = $0 { true } else { false } })
  }

  @Test
  func cancellationDuringAuthorizationExecutesNothing() async {
    let call = ToolCall(
      id: ToolCallID(rawValue: "auth-cancel"),
      name: "echo",
      arguments: [:]
    )
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [RuntimeTestFixture.model()],
      scripts: [.events(RuntimeTestFixture.toolEvents([call]))]
    )
    let executor = ScriptedToolExecutor(tools: [RuntimeTestFixture.tool()])
    let authorization = ScriptedAuthorizationProvider(mode: .suspend)
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: executor,
      authorization: authorization,
      journal: journal
    )
    let task = Task { try await runtime.run(RuntimeTestFixture.request()) }
    await waitUntil { await authorization.requests().count == 1 }

    task.cancel()
    await expectCancellation(task)

    #expect(await executor.calls().isEmpty)
    let events = await journal.events()
    #expect(!events.contains { if case .toolStarted = $0 { true } else { false } })
    #expect(events.contains { if case .runCancelled = $0 { true } else { false } })
  }

  @Test
  func cancellationDuringExecutionLeavesUnmatchedStart() async {
    let call = ToolCall(
      id: ToolCallID(rawValue: "execution-cancel"),
      name: "echo",
      arguments: [:]
    )
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [RuntimeTestFixture.model()],
      scripts: [.events(RuntimeTestFixture.toolEvents([call]))]
    )
    let executor = ScriptedToolExecutor(
      tools: [RuntimeTestFixture.tool()],
      behaviors: [.suspend]
    )
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: executor,
      journal: journal
    )
    let task = Task { try await runtime.run(RuntimeTestFixture.request()) }
    await waitUntil { await executor.calls().count == 1 }

    task.cancel()
    await expectCancellation(task)

    let events = await journal.events()
    #expect(events.contains { if case .toolStarted = $0 { true } else { false } })
    #expect(!events.contains { if case .toolFinished = $0 { true } else { false } })
    #expect(events.contains { if case .runCancelled = $0 { true } else { false } })
  }

  @Test
  func returnedToolResultIsDurableBeforeCancellationIsHonored() async {
    let call = ToolCall(
      id: ToolCallID(rawValue: "returned-before-cancel"),
      name: "echo",
      arguments: [:]
    )
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [RuntimeTestFixture.model()],
      scripts: [.events(RuntimeTestFixture.toolEvents([call]))]
    )
    let executor = ScriptedToolExecutor(tools: [RuntimeTestFixture.tool()])
    let journal = RecordingEventJournal(blockOn: .toolFinished)
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: executor,
      journal: journal
    )
    let task = Task { try await runtime.run(RuntimeTestFixture.request()) }
    await waitUntil { await journal.isBlocked() }

    task.cancel()
    await journal.releaseBlockedAppend()
    await expectCancellation(task)

    let events = await journal.events()
    let startedIndex = events.firstIndex { if case .toolStarted = $0 { true } else { false } }
    let finishedIndex = events.firstIndex { if case .toolFinished = $0 { true } else { false } }
    let cancelledIndex = events.firstIndex { if case .runCancelled = $0 { true } else { false } }
    #expect(startedIndex != nil)
    #expect(finishedIndex != nil)
    #expect(cancelledIndex != nil)
    if let startedIndex, let finishedIndex, let cancelledIndex {
      #expect(startedIndex < finishedIndex)
      #expect(finishedIndex < cancelledIndex)
    }
    #expect(await executor.calls().count == 1)
  }

  @Test
  func cancellationSurfacesJournalFailureWhenRunCancelledCannotPersist() async {
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [RuntimeTestFixture.model()],
      scripts: [.suspend]
    )
    let journal = RecordingEventJournal(failOn: .runCancelled)
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: ScriptedToolExecutor(tools: []),
      journal: journal
    )
    let task = Task { try await runtime.run(RuntimeTestFixture.request()) }
    await waitUntil { await provider.requests().count == 1 }

    task.cancel()

    do {
      _ = try await task.value
      Issue.record("Expected terminal journal failure.")
    } catch AgentRuntimeError.journalFailure {
      // Terminal persistence failure takes precedence over cancellation.
    } catch {
      Issue.record("Expected journalFailure, received: \(error)")
    }

    let events = await journal.events()
    #expect(!events.contains { if case .runCancelled = $0 { true } else { false } })
    #expect(!events.contains { if case .runFailed = $0 { true } else { false } })
  }

  @Test
  func cancellationAfterPersistingRunStartedWritesCancelledTerminal() async {
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [RuntimeTestFixture.model()],
      scripts: [.events(RuntimeTestFixture.textEvents())]
    )
    let journal = RecordingEventJournal(cancelAfterPersistOn: .runStarted)
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: ScriptedToolExecutor(tools: []),
      journal: journal
    )
    let task = Task { try await runtime.run(RuntimeTestFixture.request()) }

    await expectCancellation(task)

    let events = await journal.events()
    #expect(events.count == 2)
    #expect(events.contains { if case .runStarted = $0 { true } else { false } })
    #expect(events.contains { if case .runCancelled = $0 { true } else { false } })
    #expect(!events.contains { if case .runFailed = $0 { true } else { false } })
    #expect(!events.contains { if case .runCompleted = $0 { true } else { false } })
  }

  @Test
  func cancellationAfterPersistingRunCompletedKeepsCompletedAsSoleTerminal() async throws {
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [RuntimeTestFixture.model()],
      scripts: [.events(RuntimeTestFixture.textEvents())]
    )
    let journal = RecordingEventJournal(cancelAfterPersistOn: .runCompleted)
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: ScriptedToolExecutor(tools: []),
      journal: journal
    )
    let request = RuntimeTestFixture.request()
    let task = Task { try await runtime.run(request) }

    let result = try await task.value

    #expect(result.runID == request.runID)
    let events = await journal.events()
    let terminals = events.filter { event in
      switch event {
      case .runCompleted, .runCancelled, .runFailed:
        true
      default:
        false
      }
    }
    #expect(terminals.count == 1)
    #expect(terminals.contains { if case .runCompleted = $0 { true } else { false } })
  }

  private func expectCancellation(_ task: Task<AgentRunResult, any Error>) async {
    do {
      _ = try await task.value
      Issue.record("Expected CancellationError.")
    } catch is CancellationError {
      // Expected cancellation boundary.
    } catch {
      Issue.record("Expected CancellationError, received: \(error)")
    }
  }

  private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async {
    for _ in 0..<10_000 {
      if await condition() {
        return
      }
      await Task.yield()
    }
    Issue.record("Timed out waiting for the scripted boundary.")
  }
}
