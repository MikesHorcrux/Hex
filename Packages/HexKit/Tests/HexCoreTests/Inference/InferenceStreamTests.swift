import HexCore
import Testing

@Suite("Inference stream lifetime")
struct InferenceStreamTests {
  @Test
  func earlyReturnCancelsAndWaitsForTermination() async throws {
    let probe = LifecycleProbe()
    let stream = makeOpenStream(probe: probe)
    let consumer = Task {
      let value = try await stream.consume { cursor in
        while let event = try await cursor.next() {
          if case .started = event {
            return 7
          }
        }
        return 0
      }
      await probe.recordConsumerReturn()
      return value
    }

    await waitForCancellation(probe)
    #expect(await probe.cancellationCount() == 1)
    #expect(await probe.consumerReturnCount() == 0)
    await probe.releaseTermination()

    #expect(try await consumer.value == 7)
    #expect(await probe.terminationCount() == 1)
    #expect(await probe.consumerReturnCount() == 1)
  }

  @Test
  func closureThrowCancelsAndWaitsBeforeRethrowing() async throws {
    let probe = LifecycleProbe()
    let stream = makeOpenStream(probe: probe)
    let consumer = Task {
      try await stream.consume { cursor in
        while let event = try await cursor.next() {
          if case .started = event {
            throw ProbeError.expected
          }
        }
      }
    }

    await waitForCancellation(probe)
    #expect(await probe.cancellationCount() == 1)
    #expect(!consumer.isCancelled)
    await probe.releaseTermination()

    await #expect(throws: ProbeError.expected) {
      try await consumer.value
    }
    #expect(await probe.terminationCount() == 1)
  }

  @Test
  func taskCancellationCancelsAndWaitsBeforeReturningCancellation() async throws {
    let probe = LifecycleProbe()
    let stream = makeOpenStream(probe: probe, yieldsStarted: false)
    let consumer = Task {
      try await stream.consume { cursor in
        await probe.recordBodyEntry()
        while try await cursor.next() != nil {}
      }
    }

    for _ in 0..<1_000 where await probe.bodyEntryCount() == 0 {
      await Task.yield()
    }
    #expect(await probe.bodyEntryCount() == 1)
    consumer.cancel()
    await waitForCancellation(probe)
    #expect(await probe.cancellationCount() == 1)
    await probe.releaseTermination()

    await #expect(throws: CancellationError.self) {
      try await consumer.value
    }
    #expect(await probe.terminationCount() == 1)
  }

  @Test
  func naturalEOFCancelsResidualWorkAndWaitsOnce() async throws {
    let probe = LifecycleProbe(terminationReleased: true)
    let stream = makeFinishedStream(probe: probe)

    let events = try await stream.consume { cursor in
      var collected: [InferenceStreamEvent] = []
      while let event = try await cursor.next() {
        collected.append(event)
      }
      return collected
    }

    #expect(events == [.started(providerResponseID: nil), .completed(.stop)])
    await waitForCancellation(probe)
    #expect(await probe.cancellationCount() == 1)
    #expect(await probe.terminationCount() == 1)
  }

  @Test
  func droppingNeverConsumedStreamRequestsCancellation() async {
    let probe = LifecycleProbe()
    var stream: InferenceStream? = makeOpenStream(probe: probe)
    #expect(stream != nil)

    stream = nil
    await waitForCancellation(probe)

    #expect(await probe.cancellationCount() == 1)
    #expect(await probe.terminationCount() == 0)
    await probe.releaseTermination()
  }

  @Test
  func concurrentAndRepeatedConsumptionFailPredictably() async throws {
    let probe = LifecycleProbe(terminationReleased: true)
    let bodyGate = BodyGate()
    let stream = makeFinishedStream(probe: probe)
    let first = Task {
      try await stream.consume { _ in
        await bodyGate.enterAndWait()
        return 1
      }
    }
    await bodyGate.waitUntilEntered()

    await #expect(throws: InferenceStreamError.alreadyConsumed) {
      _ = try await stream.consume { _ in 2 }
    }
    await bodyGate.release()
    #expect(try await first.value == 1)
    await #expect(throws: InferenceStreamError.alreadyConsumed) {
      _ = try await stream.consume { _ in 3 }
    }
  }

  @Test
  func temporaryStreamRemainsOwnedThroughConsumption() async throws {
    let probe = LifecycleProbe(terminationReleased: true)

    let value = try await makeFinishedStream(probe: probe).consume { cursor in
      var count = 0
      while try await cursor.next() != nil {
        count += 1
      }
      return count
    }

    #expect(value == 2)
    await waitForCancellation(probe)
    #expect(await probe.cancellationCount() == 1)
    #expect(await probe.terminationCount() == 1)
  }

  @Test
  func cancellationWinsOverAConcurrentBodyError() async throws {
    let probe = LifecycleProbe(terminationReleased: true)
    let bodyGate = BodyGate()
    let stream = makeFinishedStream(probe: probe)
    let consumer = Task {
      try await stream.consume { _ in
        await bodyGate.enterAndWait()
        throw ProbeError.expected
      }
    }
    await bodyGate.waitUntilEntered()

    consumer.cancel()
    await bodyGate.release()

    await #expect(throws: CancellationError.self) {
      try await consumer.value
    }
  }

  @Test
  func cancellationBeforeConsumptionPreventsConsumption() async throws {
    let probe = LifecycleProbe(terminationReleased: true)
    let stream = makeFinishedStream(probe: probe)

    await stream.cancelAndWait()

    await #expect(throws: InferenceStreamError.cancelled) {
      _ = try await stream.consume { _ in 1 }
    }
  }

  @Test
  func concurrentCancelAndWaitCancelsActiveConsumption() async throws {
    let probe = LifecycleProbe(terminationReleased: true)
    let bodyGate = BodyGate()
    let stream = makeFinishedStream(probe: probe)
    let consumer = Task {
      try await stream.consume { _ in
        await bodyGate.enterAndWait()
        return 1
      }
    }
    await bodyGate.waitUntilEntered()

    await stream.cancelAndWait()
    await bodyGate.release()

    await #expect(throws: InferenceStreamError.cancelled) {
      _ = try await consumer.value
    }
    #expect(await probe.terminationCount() == 1)
  }

  private func makeOpenStream(
    probe: LifecycleProbe,
    yieldsStarted: Bool = true
  ) -> InferenceStream {
    let stream = AsyncThrowingStream<InferenceStreamEvent, any Error> { continuation in
      if yieldsStarted {
        continuation.yield(.started(providerResponseID: nil))
      }
    }
    return makeStream(events: stream, probe: probe)
  }

  private func makeFinishedStream(probe: LifecycleProbe) -> InferenceStream {
    let stream = AsyncThrowingStream<InferenceStreamEvent, any Error> { continuation in
      continuation.yield(.started(providerResponseID: nil))
      continuation.yield(.completed(.stop))
      continuation.finish()
    }
    return makeStream(events: stream, probe: probe)
  }

  private func makeStream(
    events: AsyncThrowingStream<InferenceStreamEvent, any Error>,
    probe: LifecycleProbe
  ) -> InferenceStream {
    InferenceStream(
      events: events,
      onCancellation: {
        Task {
          await probe.recordCancellation()
        }
      },
      waitForTermination: {
        await probe.waitForTerminationRelease()
        await probe.recordTermination()
      }
    )
  }

  private func waitForCancellation(_ probe: LifecycleProbe) async {
    for _ in 0..<1_000 where await probe.cancellationCount() == 0 {
      await Task.yield()
    }
  }

  private actor LifecycleProbe {
    private var cancellations = 0
    private var terminations = 0
    private var consumerReturns = 0
    private var bodyEntries = 0
    private var terminationReleased: Bool
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []

    init(terminationReleased: Bool = false) {
      self.terminationReleased = terminationReleased
    }

    func recordCancellation() {
      cancellations += 1
    }

    func recordTermination() {
      terminations += 1
    }

    func recordConsumerReturn() {
      consumerReturns += 1
    }

    func recordBodyEntry() {
      bodyEntries += 1
    }

    func cancellationCount() -> Int {
      cancellations
    }

    func terminationCount() -> Int {
      terminations
    }

    func consumerReturnCount() -> Int {
      consumerReturns
    }

    func bodyEntryCount() -> Int {
      bodyEntries
    }

    func waitForTerminationRelease() async {
      guard !terminationReleased else {
        return
      }
      await withCheckedContinuation { continuation in
        terminationWaiters.append(continuation)
      }
    }

    func releaseTermination() {
      terminationReleased = true
      let waiters = terminationWaiters
      terminationWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
    }
  }

  private actor BodyGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
      entered = true
      let waiters = entryWaiters
      entryWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      guard !released else {
        return
      }
      await withCheckedContinuation { continuation in
        releaseWaiters.append(continuation)
      }
    }

    func waitUntilEntered() async {
      guard !entered else {
        return
      }
      await withCheckedContinuation { continuation in
        entryWaiters.append(continuation)
      }
    }

    func release() {
      released = true
      let waiters = releaseWaiters
      releaseWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
    }
  }

  private enum ProbeError: Error {
    case expected
  }
}
