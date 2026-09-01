import Foundation
import HexCore
import Synchronization
import Testing

@testable import HexProviders

@Suite("OpenAI Responses lifetime")
struct OpenAIResponsesLifetimeTests {
  @Test
  func earlyReturnCancelsAndJoinsCancellationIgnoringTransportWork() async throws {
    let response = try makeCancellationIgnoringResponse(
      statusCode: 200,
      emitsStartedEvent: true
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-lifetime"),
      transport: TestOpenAIResponsesTransport(responses: [response.value])
    )
    let stream = try await provider.stream(OpenAIResponsesTestFixture.request())
    let completion = CompletionProbe()
    let consumer = Task {
      try await stream.consume { cursor in
        let firstEvent = try await cursor.next()
        #expect(firstEvent == .started(providerResponseID: "resp_lifetime"))
      }
      await completion.markComplete()
    }

    await waitForCancellationAndActiveWork(response)
    #expect(response.cancellation.count() == 1)
    #expect(await response.physicalWork.activeRunCount() == 1)
    #expect(!(await completion.isComplete()))

    await response.physicalWork.release()
    try await consumer.value
    #expect(await response.physicalWork.activeRunCount() == 0)
    #expect(response.cancellation.count() == 1)
  }

  @Test
  func rejectedHTTPResponseCancelsAndJoinsTransportBeforeThrowing() async throws {
    let response = try makeCancellationIgnoringResponse(
      statusCode: 500,
      emitsStartedEvent: false
    )
    let completion = CompletionProbe()
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-lifetime-http"),
      transport: TestOpenAIResponsesTransport(responses: [response.value])
    )
    let opening = Task {
      do {
        let stream = try await provider.stream(OpenAIResponsesTestFixture.request())
        await completion.markComplete()
        return stream
      } catch {
        await completion.markComplete()
        throw error
      }
    }

    await waitForCancellationAndActiveWork(response)
    #expect(response.cancellation.count() == 1)
    #expect(await response.physicalWork.activeRunCount() == 1)
    #expect(!(await completion.isComplete()))

    await response.physicalWork.release()
    await #expect(throws: OpenAIResponsesProviderError.httpFailure(statusCode: 500)) {
      _ = try await opening.value
    }
    for _ in 0..<1_000 where !(await completion.isComplete()) {
      await Task.yield()
    }
    #expect(await completion.isComplete())
    #expect(await response.physicalWork.activeRunCount() == 0)
    #expect(response.cancellation.count() == 1)
  }

  private func makeCancellationIgnoringResponse(
    statusCode: Int,
    emitsStartedEvent: Bool
  ) throws -> OwnedResponse {
    var startedEvent = Data()
    if emitsStartedEvent {
      try OpenAIResponsesTestFixture.appendEvent(
        [
          "type": "response.created",
          "sequence_number": 0,
          "response": ["id": "resp_lifetime", "status": "in_progress"],
        ],
        to: &startedEvent
      )
    }
    let physicalWork = PhysicalWorkProbe()
    let cancellation = CancellationCounter()
    let (body, continuation) = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self
    )
    let producer = Task {
      if !startedEvent.isEmpty {
        continuation.yield(startedEvent)
      }
      await physicalWork.beginAndWaitIgnoringCancellation()
      continuation.finish()
      await physicalWork.finish()
    }
    return OwnedResponse(
      value: OpenAIResponsesTransportResponse(
        statusCode: statusCode,
        body: body,
        cancel: {
          cancellation.increment()
          producer.cancel()
        },
        waitForTermination: {
          await producer.value
        }
      ),
      physicalWork: physicalWork,
      cancellation: cancellation
    )
  }

  private func waitForCancellationAndActiveWork(_ response: OwnedResponse) async {
    #expect(await response.cancellation.waitUntilIncremented())
    await response.physicalWork.waitUntilActive()
  }

  private struct OwnedResponse: Sendable {
    let value: OpenAIResponsesTransportResponse
    let physicalWork: PhysicalWorkProbe
    let cancellation: CancellationCounter
  }

  private final class CancellationCounter: Sendable {
    private let value = Mutex(0)
    private let signal: AsyncStream<Void>
    private let signalContinuation: AsyncStream<Void>.Continuation

    init() {
      (signal, signalContinuation) = AsyncStream.makeStream(
        of: Void.self,
        bufferingPolicy: .bufferingNewest(1)
      )
    }

    func increment() {
      value.withLock { count in
        count += 1
      }
      signalContinuation.yield(())
    }

    func count() -> Int {
      value.withLock { $0 }
    }

    func waitUntilIncremented() async -> Bool {
      await withTaskGroup(of: Bool.self) { group in
        group.addTask {
          var iterator = self.signal.makeAsyncIterator()
          return await iterator.next() != nil
        }
        group.addTask {
          do {
            try await Task.sleep(for: .seconds(1))
            return false
          } catch {
            return false
          }
        }
        let observed = await group.next() ?? false
        group.cancelAll()
        return observed
      }
    }
  }

  private actor CompletionProbe {
    private var complete = false

    func markComplete() {
      complete = true
    }

    func isComplete() -> Bool {
      complete
    }
  }

  private actor PhysicalWorkProbe {
    private var activeRuns = 0
    private var activeWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func beginAndWaitIgnoringCancellation() async {
      activeRuns += 1
      let pendingActiveWaiters = activeWaiters
      activeWaiters.removeAll()
      for waiter in pendingActiveWaiters {
        waiter.resume()
      }
      if !released {
        await withCheckedContinuation { continuation in
          waiters.append(continuation)
        }
      }
    }

    func finish() {
      activeRuns -= 1
    }

    func release() {
      released = true
      let pendingWaiters = waiters
      waiters.removeAll()
      for waiter in pendingWaiters {
        waiter.resume()
      }
    }

    func activeRunCount() -> Int {
      activeRuns
    }

    func waitUntilActive() async {
      guard activeRuns == 0 else {
        return
      }
      await withCheckedContinuation { continuation in
        activeWaiters.append(continuation)
      }
    }
  }
}
