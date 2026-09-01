import Foundation
import HexCore
import HexIPC
import Testing

@Suite("XPC gateway transport")
struct XPCGatewayTransportTests {
  @Test
  func handshakeRunAndOrderedEventsCrossTheInjectedConnection() async throws {
    let runID = GatewayTestValues.runID(241)
    let invocationID = GatewayTestValues.invocationID(242)
    let handshake = GatewayHandshakeResponse(
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(243)),
      gatewayInstanceID: GatewayInstanceID(rawValue: GatewayTestValues.uuid(244)),
      selectedVersion: .current,
      activeRun: nil
    )
    let start = GatewayStartRunResponse(
      runID: runID,
      disposition: .started(invocationID: invocationID)
    )
    let connection = ScriptedConnection(
      handshake: handshake,
      start: start
    )
    let transport = XPCGatewayTransport(
      connectionFactory: FixedConnectionFactory(connection: connection)
    )
    let lease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(245))

    #expect(
      try await transport.handshake(GatewayTestValues.handshakeRequest(), lease: lease) == handshake
    )
    #expect(
      try await transport.startRun(GatewayTestValues.request(runID: runID), lease: lease) == start)

    let stream = try await transport.eventRecords(
      after: GatewayEventCursor(runID: runID, invocationID: invocationID),
      lease: lease
    )
    let first = GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted)
    let second = GatewayTestValues.record(runID: runID, sequence: 2, event: .runCompleted)
    await connection.emit(first, invocationID: invocationID)
    await connection.emit(second, invocationID: invocationID)
    await connection.finishEvents()

    #expect(try await GatewayTestValues.collect(stream) == [first, second])
    #expect(await connection.operations == [.handshake, .startRun, .subscribeEvents])
  }

  @Test
  func disconnectSendsLeaseBoundOperationAndInvalidatesThePhysicalConnection() async throws {
    let handshake = GatewayHandshakeResponse(
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(251)),
      gatewayInstanceID: GatewayInstanceID(rawValue: GatewayTestValues.uuid(252)),
      selectedVersion: .current,
      activeRun: nil
    )
    let connection = ScriptedConnection(
      handshake: handshake,
      start: GatewayStartRunResponse(
        runID: GatewayTestValues.runID(253),
        disposition: .started(invocationID: GatewayTestValues.invocationID(254))
      )
    )
    let transport = XPCGatewayTransport(
      connectionFactory: FixedConnectionFactory(connection: connection)
    )
    let lease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(255))
    _ = try await transport.handshake(GatewayTestValues.handshakeRequest(), lease: lease)

    await transport.disconnect(lease: lease)
    #expect(await connection.operations == [.handshake, .disconnect])
    #expect(await connection.wasInvalidated)

    do {
      _ = try await transport.startRun(
        GatewayTestValues.request(runID: GatewayTestValues.runID(253)),
        lease: lease
      )
      Issue.record("Expected operations after disconnect to be rejected.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .notConnected)
    }
  }

  @Test
  func remoteFailureIsReturnedAsCanonicalGatewayFailure() async throws {
    let handshake = GatewayHandshakeResponse(
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(161)),
      gatewayInstanceID: GatewayInstanceID(rawValue: GatewayTestValues.uuid(162)),
      selectedVersion: .current,
      activeRun: nil
    )
    let failure = GatewayFailure(
      code: .capacityExceeded,
      message: "capacity is full",
      isRetryable: true
    )
    let connection = ScriptedConnection(
      handshake: handshake,
      start: nil,
      startFailure: failure
    )
    let transport = XPCGatewayTransport(
      connectionFactory: FixedConnectionFactory(connection: connection)
    )
    let lease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(163))
    _ = try await transport.handshake(GatewayTestValues.handshakeRequest(), lease: lease)

    do {
      _ = try await transport.startRun(
        GatewayTestValues.request(runID: GatewayTestValues.runID(164)),
        lease: lease
      )
      Issue.record("Expected the scripted gateway failure.")
    } catch let received as GatewayFailure {
      #expect(received == failure)
    }
  }

  @Test
  func exportedServiceAdaptsHandshakeRunAndEventSubscription() async throws {
    let driver = ImmediateGatewayRunDriver()
    let gateway = HexGatewayService(driver: driver)
    let exportedService = HexGatewayXPCService(service: gateway)
    let codec = GatewayWireCodec(configuration: .standard)
    let lease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(171))
    let handshakeRequest = GatewayTestValues.handshakeRequest(172)
    let handshakeEnvelope = try codec.encode(
      GatewayXPCRequestEnvelope(
        operation: .handshake,
        lease: lease,
        body: try codec.encode(handshakeRequest)
      )
    )
    let handshakeResponseData = try await sendRequest(
      handshakeEnvelope,
      to: exportedService
    )
    let handshakeResponse = try responseValue(
      handshakeResponseData,
      operation: .handshake,
      as: GatewayHandshakeResponse.self,
      codec: codec
    )

    let runID = GatewayTestValues.runID(173)
    let startRequest = GatewayTestValues.request(runID: runID)
    let startEnvelope = try codec.encode(
      GatewayXPCRequestEnvelope(
        operation: .startRun,
        lease: lease,
        sessionID: handshakeResponse.sessionID,
        body: try codec.encode(startRequest)
      )
    )
    let sinkStore = EventSinkStore()
    let sink = RecordingEventSink(store: sinkStore)
    let subscriptionID = GatewayXPCSubscriptionID()
    // The gateway needs a run generation before it can accept the cursor. Start first, then use the
    // invocation identity returned by admission to subscribe to the ordered stream.
    let startResponseData = try await sendRequest(startEnvelope, to: exportedService)
    let startResponse = try responseValue(
      startResponseData,
      operation: .startRun,
      as: GatewayStartRunResponse.self,
      codec: codec
    )
    let invocationID = try #require(startResponse.invocationID)
    let validSubscribeEnvelope = try codec.encode(
      GatewayXPCRequestEnvelope(
        operation: .subscribeEvents,
        lease: lease,
        sessionID: handshakeResponse.sessionID,
        subscriptionID: subscriptionID,
        body: try codec.encode(
          GatewayEventCursor(runID: runID, invocationID: invocationID)
        )
      )
    )
    _ = try await sendSubscribe(
      validSubscribeEnvelope,
      sink: sink,
      to: exportedService
    )
    await sinkStore.waitUntilFinished()
    let eventData = await sinkStore.events
    #expect(eventData.count == 2)
    let events = try eventData.map {
      try codec.decode(GatewayEventEnvelope.self, from: $0)
    }
    #expect(events.map(\.record.sequence) == [1, 2])
    #expect(await sinkStore.completionFailure == nil)
  }

  private actor ScriptedConnection: HexGatewayXPCConnection {
    private let codec = GatewayWireCodec(configuration: .standard)
    private let handshakeResponse: GatewayHandshakeResponse
    private let startResponse: GatewayStartRunResponse?
    private let startFailure: GatewayFailure?
    private var eventContinuations:
      [GatewayXPCSubscriptionID: AsyncThrowingStream<Data, any Error>.Continuation] = [:]
    private(set) var operations: [GatewayXPCOperation] = []
    private(set) var wasInvalidated = false

    init(
      handshake: GatewayHandshakeResponse,
      start: GatewayStartRunResponse?,
      startFailure: GatewayFailure? = nil
    ) {
      handshakeResponse = handshake
      startResponse = start
      self.startFailure = startFailure
    }

    func request(_ rawEnvelope: Data) async throws -> Data {
      let envelope = try codec.decode(GatewayXPCRequestEnvelope.self, from: rawEnvelope)
      operations.append(envelope.operation)
      switch envelope.operation {
      case .handshake:
        return try response(operation: .handshake, value: handshakeResponse)
      case .startRun:
        if let startFailure {
          return try codec.encode(
            GatewayXPCResponseEnvelope(operation: .startRun, failure: startFailure)
          )
        }
        guard let startResponse else {
          throw GatewayFailure(code: .transportUnavailable, message: "No scripted start response.")
        }
        return try response(operation: .startRun, value: startResponse)
      case .cancelRun:
        return try codec.encode(
          GatewayXPCResponseEnvelope(
            operation: .cancelRun,
            failure: GatewayFailure(code: .runNotFound, message: "not scripted")
          )
        )
      case .disconnect, .cancelSubscription:
        return try codec.encode(
          GatewayXPCResponseEnvelope(operation: envelope.operation, body: nil)
        )
      case .subscribeEvents:
        throw GatewayFailure(code: .malformedPayload, message: "subscription uses subscribe")
      }
    }

    func subscribe(
      _ rawEnvelope: Data,
      bufferCapacity: Int
    ) async throws -> GatewayXPCEventSubscription {
      let envelope = try codec.decode(GatewayXPCRequestEnvelope.self, from: rawEnvelope)
      guard envelope.operation == .subscribeEvents,
        let subscriptionID = envelope.subscriptionID
      else {
        throw GatewayFailure(code: .malformedPayload, message: "invalid subscription")
      }
      operations.append(.subscribeEvents)
      let pair = AsyncThrowingStream<Data, any Error>.makeStream(
        bufferingPolicy: .bufferingOldest(bufferCapacity)
      )
      eventContinuations[subscriptionID] = pair.continuation
      return GatewayXPCEventSubscription(
        id: subscriptionID,
        stream: pair.stream,
        cancellation: { [self] in
          await self.cancelSubscription(rawEnvelope)
        }
      )
    }

    func cancelSubscription(_ rawEnvelope: Data) async {
      guard let envelope = try? codec.decode(GatewayXPCRequestEnvelope.self, from: rawEnvelope),
        let subscriptionID = envelope.subscriptionID
      else {
        return
      }
      eventContinuations.removeValue(forKey: subscriptionID)?.finish()
      operations.append(.cancelSubscription)
    }

    func invalidate() async {
      wasInvalidated = true
      for continuation in eventContinuations.values {
        continuation.finish(throwing: GatewayFailure(code: .disconnected, message: "invalidated"))
      }
      eventContinuations.removeAll()
    }

    func emit(_ record: AgentEventRecord, invocationID: GatewayRunInvocationID) {
      let envelope = GatewayEventEnvelope(invocationID: invocationID, record: record)
      guard let data = try? codec.encode(envelope) else {
        return
      }
      for continuation in eventContinuations.values {
        _ = continuation.yield(data)
      }
    }

    func finishEvents() {
      for continuation in eventContinuations.values {
        continuation.finish()
      }
      eventContinuations.removeAll()
    }

    private func response<Value: Codable & Sendable>(
      operation: GatewayXPCOperation,
      value: Value
    ) throws -> Data {
      let body = try codec.encode(value)
      return try codec.encode(
        GatewayXPCResponseEnvelope(operation: operation, body: body)
      )
    }
  }

  private actor ResponseStore {
    private var value: Data?

    func set(_ value: Data) {
      self.value = value
    }

    func wait() async -> Data {
      while value == nil {
        await Task.yield()
      }
      return value ?? Data()
    }
  }

  private actor EventSinkStore {
    private(set) var events: [Data] = []
    private(set) var completionFailure: GatewayFailure?
    private var isFinished = false

    func append(_ event: Data) {
      events.append(event)
    }

    func finish(_ response: Data) {
      let codec = GatewayWireCodec(configuration: .standard)
      if let envelope = try? codec.decode(GatewayXPCResponseEnvelope.self, from: response),
        let failure = envelope.failure
      {
        completionFailure = failure
      }
      isFinished = true
    }

    func waitUntilFinished() async {
      while !isFinished {
        await Task.yield()
      }
    }
  }

  private final class RecordingEventSink: NSObject, HexGatewayXPCEventSinkProtocol {
    private let store: EventSinkStore

    init(store: EventSinkStore) {
      self.store = store
      super.init()
    }

    func receiveEvent(_ envelope: Data) {
      Task {
        await store.append(envelope)
      }
    }

    func finish(_ response: Data) {
      Task {
        await store.finish(response)
      }
    }
  }

  private func sendRequest(
    _ envelope: Data,
    to service: HexGatewayXPCService
  ) async throws -> Data {
    let store = ResponseStore()
    service.request(envelope) { response in
      Task {
        await store.set(response)
      }
    }
    return await store.wait()
  }

  private func sendSubscribe(
    _ envelope: Data,
    sink: RecordingEventSink,
    to service: HexGatewayXPCService
  ) async throws -> Data {
    let store = ResponseStore()
    service.subscribe(envelope, sink: sink) { response in
      Task {
        await store.set(response)
      }
    }
    return await store.wait()
  }

  private func responseValue<Value: Codable & Sendable>(
    _ data: Data,
    operation: GatewayXPCOperation,
    as type: Value.Type,
    codec: GatewayWireCodec
  ) throws -> Value {
    let response = try codec.decode(GatewayXPCResponseEnvelope.self, from: data).validated()
    #expect(response.operation == operation)
    if let failure = response.failure {
      throw failure
    }
    return try codec.decode(type, from: try #require(response.body))
  }

  private struct FixedConnectionFactory: HexGatewayXPCConnectionFactory {
    let connection: ScriptedConnection

    func makeConnection() -> any HexGatewayXPCConnection {
      connection
    }
  }
}
