import HexCore
import HexRuntime
import Testing

@Suite("AgentRuntime authorization lifecycle")
struct AgentRuntimeAuthorizationLifecycleTests {
  @Test
  func endsRunAuthorityAfterSuccess() async throws {
    let authorization = ScriptedAuthorizationProvider()
    let runtime = RuntimeTestFixture.runtime(
      provider: ScriptedInferenceProvider(
        descriptor: RuntimeTestFixture.descriptor(),
        models: [RuntimeTestFixture.model()],
        scripts: [.events(RuntimeTestFixture.textEvents())]
      ),
      executor: ScriptedToolExecutor(tools: []),
      authorization: authorization
    )
    let request = RuntimeTestFixture.request()

    _ = try await runtime.run(request)

    #expect(await authorization.endedRunIDs() == [request.runID])
  }

  @Test
  func endsRunAuthorityAfterFailure() async {
    let authorization = ScriptedAuthorizationProvider()
    let runtime = RuntimeTestFixture.runtime(
      provider: ScriptedInferenceProvider(
        descriptor: RuntimeTestFixture.descriptor(),
        models: [RuntimeTestFixture.model()],
        scripts: [.openingFailure]
      ),
      executor: ScriptedToolExecutor(tools: []),
      authorization: authorization
    )
    let request = RuntimeTestFixture.request()

    do {
      _ = try await runtime.run(request)
      Issue.record("Expected provider failure.")
    } catch {
      #expect(error is AgentRuntimeError)
    }

    #expect(await authorization.endedRunIDs() == [request.runID])
  }

  @Test
  func endsRunAuthorityAfterCancellation() async {
    let authorization = ScriptedAuthorizationProvider()
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [RuntimeTestFixture.model()],
      scripts: [.suspend]
    )
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: ScriptedToolExecutor(tools: []),
      authorization: authorization
    )
    let request = RuntimeTestFixture.request()
    let task = Task { try await runtime.run(request) }
    await waitUntil { await provider.requests().count == 1 }

    task.cancel()
    await expectCancellation(task)

    #expect(await authorization.endedRunIDs() == [request.runID])
  }

  @Test
  func duplicateCallerCannotEndAuthorityOwnedByActiveRun() async {
    let authorization = ScriptedAuthorizationProvider()
    let provider = ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [RuntimeTestFixture.model()],
      scripts: [.suspend]
    )
    let runtime = RuntimeTestFixture.runtime(
      provider: provider,
      executor: ScriptedToolExecutor(tools: []),
      authorization: authorization
    )
    let request = RuntimeTestFixture.request()
    let activeTask = Task { try await runtime.run(request) }
    await waitUntil { await provider.requests().count == 1 }

    do {
      _ = try await runtime.run(request)
      Issue.record("Expected duplicateRun.")
    } catch AgentRuntimeError.duplicateRun(let duplicateID) {
      #expect(duplicateID == request.runID)
    } catch {
      Issue.record("Expected duplicateRun, received: \(error)")
    }

    #expect(await authorization.endedRunIDs().isEmpty)
    activeTask.cancel()
    await expectCancellation(activeTask)
    #expect(await authorization.endedRunIDs() == [request.runID])
  }

  private func expectCancellation(_ task: Task<AgentRunResult, any Error>) async {
    do {
      _ = try await task.value
      Issue.record("Expected CancellationError.")
    } catch is CancellationError {
      // Expected.
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
