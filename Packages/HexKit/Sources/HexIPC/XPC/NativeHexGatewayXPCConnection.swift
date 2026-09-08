@preconcurrency import Foundation

/// Native Foundation XPC client connection. NSXPCConnection is kept entirely inside this actor;
/// only bounded Data and Sendable stream values cross the Swift concurrency boundary.
public actor NativeHexGatewayXPCConnection: HexGatewayXPCConnection {
  private struct EventState {
    let token: UUID
    let continuation: GatewayBufferedStream<Data>.Continuation
    let sink: EventSink
    let cancellationEnvelope: Data
  }

  private let machServiceName: String
  private let configuration: GatewayConfiguration
  private let codec: GatewayWireCodec
  private let connection: NSXPCConnection
  private var didConfigureConnection = false
  private var isUnavailable = false
  private var pendingReplies: [UUID: CheckedContinuation<Data, any Error>] = [:]
  private var events: [GatewayXPCSubscriptionID: EventState] = [:]

  public init(
    machServiceName: String,
    configuration: GatewayConfiguration = .standard
  ) {
    self.machServiceName = machServiceName
    self.configuration = configuration
    codec = GatewayWireCodec(configuration: configuration)
    connection = NSXPCConnection(machServiceName: machServiceName, options: [])
  }

  public func request(_ envelope: Data) async throws -> Data {
    try Task.checkCancellation()
    guard envelope.count <= configuration.maximumWireBytes else {
      throw GatewayFailure(
        code: .payloadTooLarge,
        message: "The XPC request envelope exceeds the configured size limit."
      )
    }
    try ensureConnection()
    let requestID = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Data, any Error>) in
        pendingReplies[requestID] = continuation
        sendRequest(envelope, requestID: requestID)
      }
    } onCancel: {
      Task {
        await self.cancelPendingReply(requestID)
      }
    }
  }

  public func subscribe(
    _ envelope: Data,
    bufferCapacity: Int
  ) async throws -> GatewayXPCEventSubscription {
    guard bufferCapacity > 0, bufferCapacity <= configuration.subscriberBufferCapacity else {
      throw GatewayFailure(
        code: .malformedPayload,
        message: "The XPC event buffer capacity must fit the configured subscriber limit."
      )
    }
    try Task.checkCancellation()
    guard envelope.count <= configuration.maximumWireBytes else {
      throw GatewayFailure(
        code: .payloadTooLarge,
        message: "The XPC subscription envelope exceeds the configured size limit."
      )
    }
    try ensureConnection()
    let requestEnvelope = try codec.decode(GatewayXPCRequestEnvelope.self, from: envelope)
    guard requestEnvelope.operation == .subscribeEvents,
      let subscriptionID = requestEnvelope.subscriptionID
    else {
      throw GatewayFailure(
        code: .malformedPayload,
        message: "The XPC subscription envelope is malformed."
      )
    }
    guard events[subscriptionID] == nil else {
      throw GatewayFailure(
        code: .conflictingRunRequest,
        message: "The XPC subscription identifier is already active.")
    }
    let cancellationEnvelope = try codec.encode(requestEnvelope.cancellationEnvelope())
    let token = UUID()
    let pair = GatewayBufferedStream<Data>.makeStream(
      bufferCapacity: bufferCapacity,
      maximumBufferedBytes: configuration.maximumBufferedWireBytesPerSubscriber
    )
    let continuation = pair.continuation
    let maximumWireBytes = configuration.maximumWireBytes
    let codec = self.codec
    let sink = EventSink(
      receiveEvent: { data in
        // Reserve payload bytes before returning from the XPC callback. Creating a Task per
        // payload would retain unaccounted Data and let terminal cleanup overtake queued events.
        Self.receiveEvent(data, maximumWireBytes: maximumWireBytes, into: continuation)
      },
      finish: { data in
        Self.finishEvent(response: data, codec: codec, into: continuation)
      }
    )
    events[subscriptionID] = EventState(
      token: token,
      continuation: continuation,
      sink: sink,
      cancellationEnvelope: cancellationEnvelope
    )
    continuation.onTermination = { @Sendable [weak self] termination in
      Task {
        switch termination {
        case .finished(nil):
          await self?.removeCompletedSubscription(subscriptionID, expectedToken: token)
        default:
          await self?.cancelSubscription(cancellationEnvelope, expectedToken: token)
        }
      }
    }

    let requestID = UUID()
    do {
      let rawResponse = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Data, any Error>) in
          pendingReplies[requestID] = continuation
          sendSubscribe(envelope, sink: sink, requestID: requestID)
        }
      } onCancel: {
        Task {
          await self.cancelPendingReply(requestID)
        }
      }
      let response = try codec.decode(GatewayXPCResponseEnvelope.self, from: rawResponse)
        .validated()
      guard response.operation == GatewayXPCOperation.subscribeEvents else {
        throw GatewayFailure(
          code: .malformedPayload,
          message: "The XPC subscription reply operation did not match the request."
        )
      }
      if let failure = response.failure {
        throw codec.canonicalFailure(from: failure)
      }
    } catch {
      if events[subscriptionID]?.token == token {
        // onTermination owns cleanup, including cancellation of a possibly admitted remote
        // subscription whose acknowledgement was lost. An old sink never removes a newer slot.
        continuation.finish(throwing: codec.canonicalFailure(from: error))
      }
      throw codec.canonicalFailure(from: error)
    }

    return GatewayXPCEventSubscription(
      id: subscriptionID,
      stream: pair.stream,
      cancellation: { [weak self] in
        await self?.cancelSubscription(cancellationEnvelope, expectedToken: token)
      }
    )
  }

  public func cancelSubscription(_ envelope: Data) async {
    await cancelSubscription(envelope, expectedToken: nil)
  }

  private func cancelSubscription(_ envelope: Data, expectedToken: UUID?) async {
    guard let request = try? codec.decode(GatewayXPCRequestEnvelope.self, from: envelope),
      request.operation == .cancelSubscription,
      let subscriptionID = request.subscriptionID
    else {
      return
    }

    guard let current = events[subscriptionID],
      current.cancellationEnvelope == envelope,
      expectedToken == nil || current.token == expectedToken,
      let state = events.removeValue(forKey: subscriptionID)
    else {
      return
    }
    state.continuation.finish()
    guard !isUnavailable else {
      return
    }
    guard let rawEnvelope = try? codec.encode(request) else {
      return
    }
    let requestID = UUID()
    do {
      _ = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Data, any Error>) in
          pendingReplies[requestID] = continuation
          sendRequest(rawEnvelope, requestID: requestID)
        }
      } onCancel: {
        Task {
          await self.cancelPendingReply(requestID)
        }
      }
    } catch {
      // Stream cancellation is already complete locally. A disconnected service is an expected
      // race, and the next handshake will create a fresh physical connection.
    }
  }

  private func removeCompletedSubscription(
    _ subscriptionID: GatewayXPCSubscriptionID, expectedToken: UUID
  ) {
    guard events[subscriptionID]?.token == expectedToken else { return }
    events.removeValue(forKey: subscriptionID)
  }

  public func invalidate() async {
    guard !isUnavailable else {
      return
    }
    isUnavailable = true
    connection.invalidationHandler = nil
    connection.interruptionHandler = nil
    connection.invalidate()
    let failure = GatewayFailure(
      code: .disconnected,
      message: "The XPC gateway connection was invalidated.",
      isRetryable: true
    )
    let replies = pendingReplies.values
    pendingReplies.removeAll()
    for continuation in replies {
      continuation.resume(throwing: failure)
    }
    let streams = events.values
    events.removeAll()
    for state in streams {
      state.continuation.finish(throwing: failure)
    }
  }

  private func ensureConnection() throws {
    guard !isUnavailable else {
      throw GatewayFailure(
        code: .transportUnavailable,
        message: "The XPC gateway connection is unavailable.",
        isRetryable: true
      )
    }
    guard !didConfigureConnection else {
      return
    }

    let serviceInterface = HexGatewayXPCService.interface()
    connection.remoteObjectInterface = serviceInterface
    connection.invalidationHandler = { [weak self] in
      Task {
        await self?.connectionBecameUnavailable()
      }
    }
    connection.interruptionHandler = { [weak self] in
      Task {
        await self?.connectionBecameUnavailable()
      }
    }
    connection.activate()
    didConfigureConnection = true
  }

  private func sendRequest(_ envelope: Data, requestID: UUID) {
    guard
      let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
        Task {
          await self?.failReply(requestID, error: error)
        }
      }) as? HexGatewayXPCServiceProtocol
    else {
      failReply(
        requestID,
        error: GatewayFailure(
          code: .transportUnavailable,
          message: "The XPC gateway proxy could not be created.",
          isRetryable: true
        )
      )
      return
    }
    proxy.request(envelope) { [weak self] response in
      Task {
        await self?.completeReply(requestID, response: response)
      }
    }
  }

  private func sendSubscribe(
    _ envelope: Data,
    sink: EventSink,
    requestID: UUID
  ) {
    guard
      let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
        Task {
          await self?.failReply(requestID, error: error)
        }
      }) as? HexGatewayXPCServiceProtocol
    else {
      failReply(
        requestID,
        error: GatewayFailure(
          code: .transportUnavailable,
          message: "The XPC gateway proxy could not be created.",
          isRetryable: true
        )
      )
      return
    }
    proxy.subscribe(envelope, sink: sink) { [weak self] response in
      Task {
        await self?.completeReply(requestID, response: response)
      }
    }
  }

  private func completeReply(_ requestID: UUID, response: Data) {
    guard let continuation = pendingReplies.removeValue(forKey: requestID) else {
      return
    }
    guard response.count <= configuration.maximumWireBytes else {
      continuation.resume(
        throwing: GatewayFailure(
          code: .payloadTooLarge,
          message: "The XPC reply envelope exceeds the configured size limit."
        )
      )
      return
    }
    continuation.resume(returning: response)
  }

  private func failReply(_ requestID: UUID, error: any Error) {
    guard let continuation = pendingReplies.removeValue(forKey: requestID) else {
      return
    }
    continuation.resume(throwing: codec.canonicalFailure(from: error))
  }

  private func cancelPendingReply(_ requestID: UUID) {
    guard let continuation = pendingReplies.removeValue(forKey: requestID) else {
      return
    }
    continuation.resume(throwing: CancellationError())
  }

  private nonisolated static func receiveEvent(
    _ data: Data,
    maximumWireBytes: Int,
    into continuation: GatewayBufferedStream<Data>.Continuation
  ) -> Bool {
    guard data.count <= maximumWireBytes else {
      continuation.finish(
        throwing: GatewayFailure(
          code: .payloadTooLarge,
          message: "The XPC event envelope exceeds the configured size limit."))
      return false
    }
    switch continuation.yield(data, wireBytes: data.count) {
    case .enqueued:
      return true
    case .dropped:
      continuation.finish(
        throwing: GatewayFailure(
          code: .consumerTooSlow,
          message: "The XPC event consumer fell behind its bounded buffer.",
          isRetryable: true
        )
      )
      return false
    case .terminated:
      return false
    @unknown default:
      continuation.finish(
        throwing: GatewayFailure(
          code: .consumerTooSlow,
          message: "The XPC event stream could not enqueue a record.",
          isRetryable: true
        )
      )
      return false
    }
  }

  private nonisolated static func finishEvent(
    response data: Data,
    codec: GatewayWireCodec,
    into continuation: GatewayBufferedStream<Data>.Continuation
  ) {
    do {
      let response = try codec.decode(GatewayXPCResponseEnvelope.self, from: data).validated()
      guard response.operation == .subscribeEvents else {
        throw GatewayFailure(
          code: .malformedPayload,
          message: "The XPC event completion operation did not match the subscription."
        )
      }
      if let failure = response.failure {
        continuation.finish(throwing: codec.canonicalFailure(from: failure))
      } else {
        continuation.finish()
      }
    } catch {
      continuation.finish(throwing: codec.canonicalFailure(from: error))
    }
  }

  private func connectionBecameUnavailable() {
    guard !isUnavailable else {
      return
    }
    isUnavailable = true
    let failure = GatewayFailure(
      code: .disconnected,
      message: "The XPC gateway connection was interrupted.",
      isRetryable: true
    )
    let replies = pendingReplies.values
    pendingReplies.removeAll()
    for continuation in replies {
      continuation.resume(throwing: failure)
    }
    let streams = events.values
    events.removeAll()
    for state in streams {
      state.continuation.finish(throwing: failure)
    }
  }

  private final class EventSink: NSObject, HexGatewayXPCEventSinkProtocol {
    private let receiveEventHandler: @Sendable (Data) -> Bool
    private let finishHandler: @Sendable (Data) -> Void

    init(
      receiveEvent: @escaping @Sendable (Data) -> Bool,
      finish: @escaping @Sendable (Data) -> Void
    ) {
      receiveEventHandler = receiveEvent
      finishHandler = finish
    }

    func receiveEvent(_ envelope: Data, withReply reply: @escaping @Sendable (Bool) -> Void) {
      reply(receiveEventHandler(envelope))
    }

    func finish(_ response: Data) {
      finishHandler(response)
    }
  }
}
