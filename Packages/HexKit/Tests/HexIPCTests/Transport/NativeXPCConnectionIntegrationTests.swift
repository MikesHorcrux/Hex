@preconcurrency import Foundation
import HexCore
import HexIPC
import Synchronization
import Testing

@Suite("Native XPC connection integration")
struct NativeXPCConnectionIntegrationTests {
  @Test
  func exportedServiceHandlesHandshakeAcrossFoundationXPC() async throws {
    let exportedService = HexGatewayXPCService(
      service: HexGatewayService(driver: ImmediateGatewayRunDriver())
    )
    let protocolService: any HexGatewayXPCServiceProtocol = exportedService
    _ = protocolService

    let listenerDelegate = HexGatewayXPCListenerDelegate(
      serviceFactory: { exportedService }
    )
    let listener = NSXPCListener.anonymous()
    listener.delegate = listenerDelegate
    listener.resume()
    defer {
      listener.invalidate()
    }

    let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
    connection.remoteObjectInterface = HexGatewayXPCService.interface()
    connection.activate()
    defer {
      connection.invalidate()
    }

    let codec = GatewayWireCodec(configuration: .standard)
    let request = GatewayTestValues.handshakeRequest(231)
    let envelope = try codec.encode(
      GatewayXPCRequestEnvelope(
        operation: .handshake,
        lease: GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(232)),
        body: try codec.encode(request)
      )
    )

    let responseData = try await send(envelope, over: connection)
    let response = try codec.decode(GatewayXPCResponseEnvelope.self, from: responseData).validated()
    #expect(response.operation == .handshake)
    #expect(response.failure == nil)
    let handshake = try codec.decode(
      GatewayHandshakeResponse.self,
      from: try #require(response.body)
    )
    #expect(handshake.selectedVersion == .current)
  }

  @Test
  func foundationXPCWaitsForAdmissionBeforeDeliveringTheNextEvent() async throws {
    let runID = GatewayTestValues.runID(233)
    let records = [
      GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted),
      GatewayTestValues.record(
        runID: runID, sequence: 2, event: .inferenceEvent(.textDelta("Hello over XPC."))),
      GatewayTestValues.record(runID: runID, sequence: 3, event: .runCompleted),
    ]
    let driver = NativeEventDriver(records: records)
    let gateway = HexGatewayService(driver: driver)
    let exportedService = HexGatewayXPCService(service: gateway)
    let listenerDelegate = HexGatewayXPCListenerDelegate(serviceFactory: { exportedService })
    defer { withExtendedLifetime(listenerDelegate) {} }
    let listener = NSXPCListener.anonymous()
    listener.delegate = listenerDelegate
    listener.resume()
    defer { listener.invalidate() }
    let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
    connection.remoteObjectInterface = HexGatewayXPCService.interface()
    connection.activate()
    defer { connection.invalidate() }
    let sink = AdmissionHoldingSink()
    defer { sink.releaseFirstAcknowledgement() }
    let codec = GatewayWireCodec(configuration: .standard)
    let lease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(234))

    do {
      let handshakeData = try await sendBounded(
        codec.encode(
          GatewayXPCRequestEnvelope(
            operation: .handshake, lease: lease,
            body: codec.encode(GatewayTestValues.handshakeRequest(235)))),
        over: connection)
      let handshakeEnvelope = try codec.decode(
        GatewayXPCResponseEnvelope.self, from: handshakeData
      ).validated()
      #expect(handshakeEnvelope.failure == nil)
      let handshake = try codec.decode(
        GatewayHandshakeResponse.self, from: #require(handshakeEnvelope.body))
      #expect(handshake.selectedVersion == .current)

      let startData = try await sendBounded(
        codec.encode(
          GatewayXPCRequestEnvelope(
            operation: .startRun, lease: lease, sessionID: handshake.sessionID,
            body: codec.encode(GatewayTestValues.request(runID: runID)))),
        over: connection)
      let startEnvelope = try codec.decode(
        GatewayXPCResponseEnvelope.self, from: startData
      ).validated()
      #expect(startEnvelope.failure == nil)
      let start = try codec.decode(
        GatewayStartRunResponse.self, from: #require(startEnvelope.body))
      let invocationID = try #require(start.invocationID)
      let subscriptionData = try await sendBounded(
        codec.encode(
          GatewayXPCRequestEnvelope(
            operation: .subscribeEvents, lease: lease, sessionID: handshake.sessionID,
            subscriptionID: GatewayXPCSubscriptionID(),
            body: codec.encode(GatewayEventCursor(runID: runID, invocationID: invocationID)))),
        over: connection, sink: sink)
      let subscription = try codec.decode(
        GatewayXPCResponseEnvelope.self, from: subscriptionData
      ).validated()
      #expect(subscription.failure == nil)

      try await sink.waitUntilFirstEvent()
      // The whole scripted response is already available at the service. Holding the first
      // actual Foundation reply must keep the next event and terminal callback off the wire.
      let emissionDeadline = ContinuousClock.now.advanced(by: .seconds(2))
      while !(await driver.didEmitAllRecords) {
        guard ContinuousClock.now < emissionDeadline else { throw NativeFixtureError.timedOut }
        try await Task.sleep(for: .milliseconds(1))
      }
      try await Task.sleep(for: .milliseconds(100))
      #expect(sink.events.count == 1)
      #expect(sink.completion == nil)
      let first = try codec.decode(GatewayEventEnvelope.self, from: #require(sink.events.first))
      #expect(first.record == records[0])
      #expect(first.invocationID == invocationID)

      sink.releaseFirstAcknowledgement()
      let completionData = try await sink.waitUntilFinished()
      let completion = try codec.decode(
        GatewayXPCResponseEnvelope.self, from: completionData
      ).validated()
      #expect(completion.operation == .subscribeEvents)
      #expect(completion.failure == nil)
      let envelopes = try sink.events.map { try codec.decode(GatewayEventEnvelope.self, from: $0) }
      #expect(envelopes.map(\.record) == records)
      #expect(envelopes.allSatisfy { $0.invocationID == invocationID })
      try await gateway.shutdown(timeout: .seconds(2))
    } catch {
      sink.releaseFirstAcknowledgement()
      connection.invalidate()
      exportedService.invalidate()
      try? await gateway.shutdown(timeout: .seconds(2))
      throw error
    }
  }

  private func sendBounded(
    _ envelope: Data, over connection: NSXPCConnection,
    sink: AdmissionHoldingSink? = nil
  ) async throws -> Data {
    let response = Mutex<Result<Data, any Error>?>(nil)
    guard
      let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
        response.withLock { if $0 == nil { $0 = .failure(error) } }
      }) as? HexGatewayXPCServiceProtocol
    else { throw NativeFixtureError.proxyUnavailable }
    let reply: @Sendable (Data) -> Void = { data in
      response.withLock { if $0 == nil { $0 = .success(data) } }
    }
    if let sink {
      proxy.subscribe(envelope, sink: sink, withReply: reply)
    } else {
      proxy.request(envelope, withReply: reply)
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while true {
      if let result = response.withLock({ $0 }) { return try result.get() }
      guard ContinuousClock.now < deadline else { throw NativeFixtureError.timedOut }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  private actor NativeEventDriver: HexGatewayRunDriver {
    let records: [AgentEventRecord]
    private(set) var didEmitAllRecords = false

    init(records: [AgentEventRecord]) { self.records = records }

    func run(
      _ request: GatewayStartRunRequest,
      emit: @escaping @Sendable (AgentEventRecord) async throws -> Void
    ) async throws {
      for record in records { try await emit(record) }
      didEmitAllRecords = true
    }
  }

  private final class AdmissionHoldingSink: NSObject, HexGatewayXPCEventSinkProtocol {
    private struct State {
      var events: [Data] = []
      var completion: Data?
      var firstReply: (@Sendable (Bool) -> Void)?
    }

    private let state = Mutex(State())
    var events: [Data] { state.withLock { $0.events } }
    var completion: Data? { state.withLock { $0.completion } }

    func receiveEvent(_ envelope: Data, withReply reply: @escaping @Sendable (Bool) -> Void) {
      let shouldReply = state.withLock {
        $0.events.append(envelope)
        if $0.events.count == 1 {
          $0.firstReply = reply
          return false
        }
        return true
      }
      if shouldReply { reply(true) }
    }

    func finish(_ response: Data) { state.withLock { $0.completion = response } }

    func releaseFirstAcknowledgement() {
      let reply = state.withLock {
        let reply = $0.firstReply
        $0.firstReply = nil
        return reply
      }
      reply?(true)
    }

    func waitUntilFirstEvent() async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while events.isEmpty {
        guard ContinuousClock.now < deadline else { throw NativeFixtureError.timedOut }
        try await Task.sleep(for: .milliseconds(1))
      }
    }

    func waitUntilFinished() async throws -> Data {
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while true {
        if let completion { return completion }
        guard ContinuousClock.now < deadline else { throw NativeFixtureError.timedOut }
        try await Task.sleep(for: .milliseconds(1))
      }
    }
  }

  private enum NativeFixtureError: Error { case proxyUnavailable, timedOut }

  private func send(
    _ envelope: Data,
    over connection: NSXPCConnection
  ) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      guard
        let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
          continuation.resume(throwing: error)
        }) as? HexGatewayXPCServiceProtocol
      else {
        continuation.resume(
          throwing: GatewayFailure(
            code: .transportUnavailable,
            message: "The native XPC proxy could not be created."
          )
        )
        return
      }
      proxy.request(envelope) { response in
        continuation.resume(returning: response)
      }
    }
  }
}
