@preconcurrency import Foundation

/// Native Foundation XPC client connection. NSXPCConnection is kept entirely inside this actor;
/// only bounded Data and Sendable stream values cross the Swift concurrency boundary.
public actor NativeHexGatewayXPCConnection: HexGatewayXPCConnection {
  private struct EventState {
    let continuation: AsyncThrowingStream<Data, any Error>.Continuation
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
    guard bufferCapacity > 0 else {
      throw GatewayFailure(
        code: .malformedPayload,
        message: "The XPC event buffer capacity must be positive."
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
    let cancellationEnvelope = try codec.encode(requestEnvelope.cancellationEnvelope())
    let pair = AsyncThrowingStream<Data, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(bufferCapacity)
    )
    let sink = EventSink(
      receiveEvent: { [weak self] data in
        Task {
          await self?.receiveEvent(data, subscriptionID: subscriptionID)
        }
      },
      finish: { [weak self] data in
        Task {
          await self?.finishEvent(response: data, subscriptionID: subscriptionID)
        }
      }
    )
    events[subscriptionID] = EventState(
      continuation: pair.continuation,
      sink: sink,
      cancellationEnvelope: cancellationEnvelope
    )
    pair.continuation.onTermination = { @Sendable [weak self] _ in
      Task {
        await self?.cancelSubscription(cancellationEnvelope)
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
      events.removeValue(forKey: subscriptionID)?.continuation.finish(
        throwing: codec.canonicalFailure(from: error)
      )
      throw codec.canonicalFailure(from: error)
    }

    return GatewayXPCEventSubscription(
      id: subscriptionID,
      stream: pair.stream,
      cancellation: { [weak self] in
        await self?.cancelSubscription(cancellationEnvelope)
      }
    )
  }

  public func cancelSubscription(_ envelope: Data) async {
    guard let request = try? codec.decode(GatewayXPCRequestEnvelope.self, from: envelope),
      request.operation == .cancelSubscription,
      let subscriptionID = request.subscriptionID
    else {
      return
    }

    guard let state = events.removeValue(forKey: subscriptionID) else {
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

  private func receiveEvent(
    _ data: Data,
    subscriptionID: GatewayXPCSubscriptionID
  ) {
    guard let state = events[subscriptionID] else {
      return
    }
    guard data.count <= configuration.maximumWireBytes else {
      finishEvent(
        response: (try? codec.encode(
          GatewayXPCResponseEnvelope(
            operation: .subscribeEvents,
            failure: GatewayFailure(
              code: .payloadTooLarge,
              message: "The XPC event envelope exceeds the configured size limit."
            )
          )
        )) ?? Data(),
        subscriptionID: subscriptionID
      )
      return
    }
    switch state.continuation.yield(data) {
    case .enqueued:
      return
    case .dropped, .terminated:
      state.continuation.finish(
        throwing: GatewayFailure(
          code: .consumerTooSlow,
          message: "The XPC event consumer fell behind its bounded buffer.",
          isRetryable: true
        )
      )
      events.removeValue(forKey: subscriptionID)
      Task {
        await cancelSubscription(state.cancellationEnvelope)
      }
    @unknown default:
      state.continuation.finish(
        throwing: GatewayFailure(
          code: .consumerTooSlow,
          message: "The XPC event stream could not enqueue a record.",
          isRetryable: true
        )
      )
      events.removeValue(forKey: subscriptionID)
      Task {
        await cancelSubscription(state.cancellationEnvelope)
      }
    }
  }

  private func finishEvent(
    response data: Data,
    subscriptionID: GatewayXPCSubscriptionID
  ) {
    guard let state = events.removeValue(forKey: subscriptionID) else {
      return
    }
    do {
      let response = try codec.decode(GatewayXPCResponseEnvelope.self, from: data).validated()
      guard response.operation == .subscribeEvents else {
        throw GatewayFailure(
          code: .malformedPayload,
          message: "The XPC event completion operation did not match the subscription."
        )
      }
      if let failure = response.failure {
        state.continuation.finish(throwing: codec.canonicalFailure(from: failure))
      } else {
        state.continuation.finish()
      }
    } catch {
      state.continuation.finish(throwing: codec.canonicalFailure(from: error))
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
    private let receiveEventHandler: @Sendable (Data) -> Void
    private let finishHandler: @Sendable (Data) -> Void

    init(
      receiveEvent: @escaping @Sendable (Data) -> Void,
      finish: @escaping @Sendable (Data) -> Void
    ) {
      receiveEventHandler = receiveEvent
      finishHandler = finish
    }

    func receiveEvent(_ envelope: Data) {
      receiveEventHandler(envelope)
    }

    func finish(_ response: Data) {
      finishHandler(response)
    }
  }
}
