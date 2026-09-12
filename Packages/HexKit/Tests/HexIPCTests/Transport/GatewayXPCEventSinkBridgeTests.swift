import Foundation
import HexIPC
import Synchronization
import Testing

@Suite("XPC acknowledged event admission")
struct GatewayXPCEventSinkBridgeTests {
  @Test("The producer cannot send its next event before bounded receiver admission")
  func serialProducerWaitsForAcknowledgement() async throws {
    let sink = ControlledSink()
    let bridge = GatewayXPCEventSinkBridge(sink: sink)
    let producer = Task {
      try await bridge.receiveEvent(Data([1]))
      try await bridge.receiveEvent(Data([2]))
    }
    try await sink.waitForEvents(1)
    #expect(sink.events == [Data([1])])
    sink.reply(to: 0, accepted: true)
    try await sink.waitForEvents(2)
    #expect(sink.events == [Data([1]), Data([2])])
    sink.reply(to: 1, accepted: true)
    try await producer.value
  }

  @Test("A second concurrent caller cannot create another in-flight payload")
  func concurrentAdmissionIsRejectedWithoutTouchingFirst() async throws {
    let sink = ControlledSink()
    let bridge = GatewayXPCEventSinkBridge(sink: sink)
    let producer = Task { try await bridge.receiveEvent(Data([1])) }
    try await sink.waitForEvents(1)
    await expectFailure(.capacityExceeded) { try await bridge.receiveEvent(Data([2])) }
    #expect(sink.events.count == 1)
    sink.reply(to: 0, accepted: true)
    try await producer.value
  }

  @Test("Rejected receiver admission seals delivery without silently dropping into another queue")
  func rejectedAdmissionSealsBridge() async throws {
    let sink = ControlledSink()
    let bridge = GatewayXPCEventSinkBridge(sink: sink)
    let producer = Task { try await bridge.receiveEvent(Data([1])) }
    try await sink.waitForEvents(1)
    sink.reply(to: 0, accepted: false)
    await expectFailure(.consumerTooSlow) { try await producer.value }
    await expectFailure(.transportUnavailable) { try await bridge.receiveEvent(Data([2])) }
    #expect(sink.events.count == 1)
  }

  @Test("A nonreplying receiver hits a real bounded deadline and cannot accumulate more sends")
  func deadlineSealsBridgeAndLateReplyCannotReopenIt() async throws {
    let sink = ControlledSink()
    let bridge = GatewayXPCEventSinkBridge(
      sink: sink, acknowledgementTimeout: .milliseconds(20))
    await expectFailure(.transportUnavailable) { try await bridge.receiveEvent(Data([1])) }
    #expect(sink.events.count == 1)
    sink.reply(to: 0, accepted: true)
    await expectFailure(.transportUnavailable) { try await bridge.receiveEvent(Data([2])) }
    #expect(sink.events.count == 1)
  }

  @Test("Connection teardown cancellation does not wait for the remote receiver's reply")
  func cancellationDrainsPendingAcknowledgement() async throws {
    let sink = ControlledSink()
    let bridge = GatewayXPCEventSinkBridge(sink: sink, acknowledgementTimeout: .seconds(60))
    let producer = Task { try await bridge.receiveEvent(Data([1])) }
    try await sink.waitForEvents(1)
    producer.cancel()
    do {
      try await producer.value
      Issue.record("Expected caller cancellation.")
    } catch is CancellationError {}
    sink.reply(to: 0, accepted: true)
    await expectFailure(.transportUnavailable) { try await bridge.receiveEvent(Data([2])) }
    #expect(sink.events.count == 1)
  }

  @Test("Duplicate late replies cannot complete the next event's acknowledgement")
  func acknowledgementIdentityIsPerPayload() async throws {
    let sink = ControlledSink()
    let bridge = GatewayXPCEventSinkBridge(sink: sink)
    let first = Task { try await bridge.receiveEvent(Data([1])) }
    try await sink.waitForEvents(1)
    sink.reply(to: 0, accepted: true)
    try await first.value
    let second = Task { try await bridge.receiveEvent(Data([2])) }
    try await sink.waitForEvents(2)
    sink.reply(to: 0, accepted: false)
    sink.reply(to: 1, accepted: true)
    try await second.value
  }

  @Test("Finishing a stream resolves any local acknowledgement waiter and seals new sends")
  func finishCannotLeaveSuspendedProducer() async throws {
    let sink = ControlledSink()
    let bridge = GatewayXPCEventSinkBridge(sink: sink)
    let producer = Task { try await bridge.receiveEvent(Data([1])) }
    try await sink.waitForEvents(1)
    await bridge.finish(Data([9]))
    await expectFailure(.transportUnavailable) { try await producer.value }
    #expect(sink.finishes == [Data([9])])
    await expectFailure(.transportUnavailable) { try await bridge.receiveEvent(Data([2])) }
  }

  private func expectFailure(
    _ code: GatewayFailureCode, operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      Issue.record("Expected gateway failure \(code).")
    } catch let failure as GatewayFailure {
      #expect(failure.code == code)
    } catch {
      Issue.record("Expected gateway failure, received \(error).")
    }
  }

  private final class ControlledSink: NSObject, HexGatewayXPCEventSinkProtocol {
    private struct State {
      var events: [Data] = []
      var replies: [@Sendable (Bool) -> Void] = []
      var finishes: [Data] = []
    }

    private let state = Mutex(State())
    var events: [Data] { state.withLock { $0.events } }
    var finishes: [Data] { state.withLock { $0.finishes } }

    func receiveEvent(_ envelope: Data, withReply reply: @escaping @Sendable (Bool) -> Void) {
      state.withLock {
        $0.events.append(envelope)
        $0.replies.append(reply)
      }
    }

    func finish(_ response: Data) { state.withLock { $0.finishes.append(response) } }

    func reply(to index: Int, accepted: Bool) {
      let reply = state.withLock { $0.replies[index] }
      reply(accepted)
    }

    func waitForEvents(_ count: Int) async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while events.count < count {
        guard ContinuousClock.now < deadline else { throw FixtureError.waitTimedOut }
        try await Task.sleep(for: .milliseconds(1))
      }
    }
  }

  private enum FixtureError: Error { case waitTimedOut }
}
