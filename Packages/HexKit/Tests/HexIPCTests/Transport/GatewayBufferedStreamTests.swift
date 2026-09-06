import Foundation
import Synchronization
import Testing

@testable import HexIPC

@Suite("Gateway byte-bounded streams")
struct GatewayBufferedStreamTests {
  @Test("An ordinary queued burst retains every item through terminal completion")
  func ordinaryBurstIsContiguous() async throws {
    let pair = GatewayBufferedStream<Data>.makeStream(
      bufferCapacity: 128, maximumBufferedBytes: 65_536)
    let expected = (0..<100).map { Data("fragment-\($0)".utf8) }
    for item in expected { #expect(enqueue(item, into: pair.continuation)) }
    pair.continuation.finish()

    var received: [Data] = []
    for try await item in pair.stream { received.append(item) }
    #expect(received == expected)
  }

  @Test("Actual byte exhaustion fails explicitly before the record-count cap")
  func byteBudgetFailurePreservesAcceptedPrefixAndReportsSlowConsumer() async throws {
    let pair = GatewayBufferedStream<Data>.makeStream(
      bufferCapacity: 8, maximumBufferedBytes: 10)
    let accepted = Data(repeating: 1, count: 6)
    #expect(enqueue(accepted, into: pair.continuation))
    #expect(!enqueue(Data(repeating: 2, count: 5), into: pair.continuation))

    var received: [Data] = []
    do {
      for try await item in pair.stream { received.append(item) }
      Issue.record("Expected the caller's explicit consumerTooSlow failure.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .consumerTooSlow)
    }
    #expect(received == [accepted])
  }

  @Test("Dequeuing releases byte capacity for later output")
  func dequeueMakesRoomForLaterItem() async throws {
    let pair = GatewayBufferedStream<Data>.makeStream(
      bufferCapacity: 8, maximumBufferedBytes: 6)
    let first = Data(repeating: 1, count: 4)
    let second = Data(repeating: 2, count: 2)
    let third = Data(repeating: 3, count: 4)
    #expect(enqueue(first, into: pair.continuation))
    #expect(enqueue(second, into: pair.continuation))
    var iterator = pair.stream.makeAsyncIterator()
    #expect(try await iterator.next() == first)
    #expect(enqueue(third, into: pair.continuation))
    pair.continuation.finish()
    #expect(try await iterator.next() == second)
    #expect(try await iterator.next() == third)
    #expect(try await iterator.next() == nil)
  }

  @Test("A generous byte allowance never disables the count cap")
  func recordCountCapStillFailsExplicitly() async throws {
    let pair = GatewayBufferedStream<Data>.makeStream(
      bufferCapacity: 2, maximumBufferedBytes: 1_024)
    #expect(enqueue(Data([1]), into: pair.continuation))
    #expect(enqueue(Data([2]), into: pair.continuation))
    #expect(!enqueue(Data([3]), into: pair.continuation))
    var received: [Data] = []
    do {
      for try await item in pair.stream { received.append(item) }
      Issue.record("Expected a record-count consumerTooSlow failure.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .consumerTooSlow)
    }
    #expect(received == [Data([1]), Data([2])])
  }

  @Test("Cancelling a waiting consumer runs its producer cleanup callback")
  func cancelledConsumerNotifiesProducer() async throws {
    let probe = CleanupProbe()
    let pair = GatewayBufferedStream<Data>.makeStream(
      bufferCapacity: 8, maximumBufferedBytes: 1_024)
    pair.continuation.onTermination = { probe.record($0) }
    #expect(enqueue(Data([1]), into: pair.continuation))
    let firstReceived = Mutex(false)
    let consumer = Task {
      var iterator = pair.stream.makeAsyncIterator()
      _ = try await iterator.next()
      firstReceived.withLock { $0 = true }
      return try await iterator.next()
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !firstReceived.withLock({ $0 }) {
      guard ContinuousClock.now < deadline else { throw FixtureError.waitTimedOut }
      try await Task.sleep(for: .milliseconds(1))
    }
    consumer.cancel()
    _ = try? await consumer.value
    try await probe.waitUntilNotified()
    #expect(probe.notifications() == ["cancelled"])
  }

  @Test("Dropping an unused stream notifies a still-retained producer")
  func abandonedStreamNotifiesProducer() async throws {
    let probe = CleanupProbe()
    let continuation = makeAbandonedStream(probe: probe)
    try await probe.waitUntilNotified()
    #expect(probe.notifications() == ["cancelled"])
    guard case .terminated = continuation.yield(Data([1]), wireBytes: 1) else {
      Issue.record("A dropped consumer must not keep accepting unreachable output.")
      continuation.finish()
      return
    }
  }

  @Test(
    "Termination releases cleanup captures even while the producer retains its continuation",
    arguments: [false, true])
  func terminationReleasesCapturedResources(cancelConsumer: Bool) async throws {
    let pair = GatewayBufferedStream<Data>.makeStream(
      bufferCapacity: 8, maximumBufferedBytes: 1_024)
    var resource: CapturedResource? = CapturedResource()
    weak var weakResource = resource
    pair.continuation.onTermination = { [resource] _ in withExtendedLifetime(resource) {} }
    resource = nil
    #expect(weakResource != nil)

    if cancelConsumer {
      #expect(enqueue(Data([1]), into: pair.continuation))
      let firstReceived = Mutex(false)
      let consumer = Task {
        var iterator = pair.stream.makeAsyncIterator()
        _ = try await iterator.next()
        firstReceived.withLock { $0 = true }
        return try await iterator.next()
      }
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while !firstReceived.withLock({ $0 }) {
        guard ContinuousClock.now < deadline else { throw FixtureError.waitTimedOut }
        try await Task.sleep(for: .milliseconds(1))
      }
      consumer.cancel()
      _ = try? await consumer.value
    } else {
      pair.continuation.finish()
    }

    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while weakResource != nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(weakResource == nil)
    withExtendedLifetime(pair) {}
  }

  @Test("A finished byte-full queue rejects later output as terminated and retains its prefix")
  func finishedFullQueueRemainsDrainableAndDoesNotReportOverflow() async throws {
    let pair = GatewayBufferedStream<Data>.makeStream(
      bufferCapacity: 8, maximumBufferedBytes: 4)
    let accepted = Data([1, 2, 3, 4])
    #expect(enqueue(accepted, into: pair.continuation))
    pair.continuation.finish()
    if case .terminated = pair.continuation.yield(Data([5]), wireBytes: 1) {
      // Termination wins over capacity exhaustion; no output may be admitted after finish.
    } else {
      Issue.record("A finished byte-full stream must report terminated, not dropped.")
    }
    var iterator = pair.stream.makeAsyncIterator()
    #expect(try await iterator.next() == accepted)
    #expect(try await iterator.next() == nil)
  }

  private func enqueue(_ value: Data, into continuation: GatewayBufferedStream<Data>.Continuation)
    -> Bool
  {
    switch continuation.yield(value, wireBytes: value.count) {
    case .enqueued:
      return true
    case .dropped:
      // This is the forwarding caller's policy, not an implicit error chosen by the primitive.
      continuation.finish(
        throwing: GatewayFailure(
          code: .consumerTooSlow,
          message: "The consumer exceeded its actual buffered output budget.",
          isRetryable: true))
      return false
    case .terminated:
      return false
    @unknown default:
      return false
    }
  }

  private func makeAbandonedStream(probe: CleanupProbe) -> GatewayBufferedStream<Data>.Continuation
  {
    let pair = GatewayBufferedStream<Data>.makeStream(
      bufferCapacity: 8, maximumBufferedBytes: 1_024)
    pair.continuation.onTermination = { probe.record($0) }
    withExtendedLifetime(pair.stream) {}
    return pair.continuation
  }

  private enum FixtureError: Error { case waitTimedOut }

  private final class CapturedResource: Sendable {}

  private final class CleanupProbe: Sendable {
    private let values = Mutex<[String]>([])

    func record(_ termination: AsyncThrowingStream<Data, any Error>.Continuation.Termination) {
      values.withLock {
        switch termination {
        case .cancelled: $0.append("cancelled")
        case .finished: $0.append("finished")
        @unknown default: $0.append("unknown")
        }
      }
    }

    func notifications() -> [String] { values.withLock { $0 } }

    func waitUntilNotified() async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while notifications().isEmpty {
        guard ContinuousClock.now < deadline else { throw FixtureError.waitTimedOut }
        try await Task.sleep(for: .milliseconds(1))
      }
    }
  }
}
