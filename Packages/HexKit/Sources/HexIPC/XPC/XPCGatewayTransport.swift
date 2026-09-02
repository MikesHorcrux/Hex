import Foundation
import HexCore

/// App-facing HexGatewayTransport backed by a fresh local XPC connection per handshake. The
/// transport owns no gateway state: the connection factory and the Data-only XPC endpoint are
/// injected, which keeps lifecycle tests independent of launchd and Mach-service registration.
public actor XPCGatewayTransport: HexGatewayTransport, HexGatewayAuthorizationDecisionTransport,
  HexGatewayResidentControlTransport
{
  private struct ConnectionState: Sendable {
    let generation: UUID
    let lease: GatewayTransportConnectionLease
    let sessionID: GatewaySessionID
    let connection: any HexGatewayXPCConnection
  }

  private struct HandshakeState: Sendable {
    let attemptID: UUID
    let lease: GatewayTransportConnectionLease
    let connection: any HexGatewayXPCConnection
  }

  private let connectionFactory: any HexGatewayXPCConnectionFactory
  private let configuration: GatewayConfiguration
  private let codec: GatewayWireCodec
  private var connected: ConnectionState?
  private var pendingHandshake: HandshakeState?

  public init(
    connectionFactory: any HexGatewayXPCConnectionFactory,
    configuration: GatewayConfiguration = .standard
  ) {
    self.connectionFactory = connectionFactory
    self.configuration = configuration
    codec = GatewayWireCodec(configuration: configuration)
  }

  /// Creates a transport for a user-session launchd Mach service. This initializer only creates
  /// NSXPCConnection objects when a handshake is attempted; it does not register or install a
  /// launch agent or request any macOS permission.
  public init(
    machServiceName: String,
    configuration: GatewayConfiguration = .standard
  ) {
    self.init(
      connectionFactory: NativeHexGatewayXPCConnectionFactory(
        machServiceName: machServiceName,
        configuration: configuration
      ),
      configuration: configuration
    )
  }

  public func handshake(
    _ request: GatewayHandshakeRequest,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayHandshakeResponse {
    let attemptID = UUID()
    let connection = connectionFactory.makeConnection()
    let previousConnection = connected?.connection
    let previousPendingConnection = pendingHandshake?.connection
    connected = nil
    pendingHandshake = HandshakeState(
      attemptID: attemptID,
      lease: lease,
      connection: connection
    )

    await previousConnection?.invalidate()
    if let previousPendingConnection {
      await previousPendingConnection.invalidate()
    }

    do {
      try requireCurrentHandshake(attemptID: attemptID, lease: lease)
      let body = try codec.encode(request)
      let envelope = try encodeEnvelope(
        GatewayXPCRequestEnvelope(
          operation: .handshake,
          lease: lease,
          body: body
        )
      )
      let rawResponse = try await connection.request(envelope)
      try requireCurrentHandshake(attemptID: attemptID, lease: lease)
      let response = try decodeResponse(
        rawResponse,
        operation: .handshake,
        as: GatewayHandshakeResponse.self
      )
      try requireCurrentHandshake(attemptID: attemptID, lease: lease)
      pendingHandshake = nil
      connected = ConnectionState(
        generation: UUID(),
        lease: lease,
        sessionID: response.sessionID,
        connection: connection
      )
      return response
    } catch {
      if pendingHandshake?.attemptID == attemptID {
        pendingHandshake = nil
      }
      await connection.invalidate()
      throw codec.canonicalFailure(from: error)
    }
  }

  public func startRun(
    _ request: GatewayStartRunRequest,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayStartRunResponse {
    let state = try requireConnected(lease: lease)
    do {
      let body = try codec.encode(request)
      let envelope = try encodeEnvelope(
        GatewayXPCRequestEnvelope(
          operation: .startRun,
          lease: lease,
          sessionID: state.sessionID,
          body: body
        )
      )
      let rawResponse = try await state.connection.request(envelope)
      try requireCurrentConnection(state)
      return try decodeResponse(
        rawResponse,
        operation: .startRun,
        as: GatewayStartRunResponse.self
      )
    } catch {
      throw codec.canonicalFailure(from: error)
    }
  }

  public func cancelRun(
    _ request: GatewayCancelRunRequest,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayCancelRunResponse {
    let state = try requireConnected(lease: lease)
    do {
      let body = try codec.encode(request)
      let envelope = try encodeEnvelope(
        GatewayXPCRequestEnvelope(
          operation: .cancelRun,
          lease: lease,
          sessionID: state.sessionID,
          body: body
        )
      )
      let rawResponse = try await state.connection.request(envelope)
      try requireCurrentConnection(state)
      return try decodeResponse(
        rawResponse,
        operation: .cancelRun,
        as: GatewayCancelRunResponse.self
      )
    } catch {
      throw codec.canonicalFailure(from: error)
    }
  }

  public func submitAuthorizationDecision(
    _ request: AuthorizationRequest,
    choice: GatewayAuthorizationDecisionChoice,
    lease: GatewayTransportConnectionLease
  ) async throws {
    let state = try requireConnected(lease: lease)
    do {
      let body = try codec.encode(
        GatewayAuthorizationDecisionRequest(request: request, choice: choice)
      )
      let envelope = try encodeEnvelope(
        GatewayXPCRequestEnvelope(
          operation: .submitAuthorizationDecision,
          lease: lease,
          sessionID: state.sessionID,
          body: body
        )
      )
      let rawResponse = try await state.connection.request(envelope)
      try requireCurrentConnection(state)
      try validateEmptyResponse(
        rawResponse,
        operation: .submitAuthorizationDecision
      )
    } catch {
      throw codec.canonicalFailure(from: error)
    }
  }

  public func status(
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayResidentStatus {
    try await residentControlResponse(operation: .status, lease: lease)
  }

  public func pauseHeartbeats(
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayResidentStatus {
    try await residentControlResponse(operation: .pauseHeartbeats, lease: lease)
  }

  public func resumeHeartbeats(
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayResidentStatus {
    try await residentControlResponse(operation: .resumeHeartbeats, lease: lease)
  }

  public func listHeartbeats(
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayHeartbeatScheduleList {
    try await residentHeartbeatResponse(
      operation: .listHeartbeats,
      body: Data(),
      lease: lease
    )
  }

  public func addHeartbeat(
    _ request: GatewayHeartbeatScheduleRequest,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayHeartbeatScheduleList {
    try await residentHeartbeatResponse(
      operation: .addHeartbeat,
      body: try codec.encode(request.validated()),
      lease: lease
    )
  }

  public func removeHeartbeat(
    _ mutation: GatewayHeartbeatScheduleMutation,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayHeartbeatScheduleList {
    try await residentHeartbeatResponse(
      operation: .removeHeartbeat,
      body: try codec.encode(mutation.validated()),
      lease: lease
    )
  }

  public func pauseHeartbeat(
    _ mutation: GatewayHeartbeatScheduleMutation,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayHeartbeatScheduleList {
    try await residentHeartbeatResponse(
      operation: .pauseHeartbeat,
      body: try codec.encode(mutation.validated()),
      lease: lease
    )
  }

  public func resumeHeartbeat(
    _ mutation: GatewayHeartbeatScheduleMutation,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayHeartbeatScheduleList {
    try await residentHeartbeatResponse(
      operation: .resumeHeartbeat,
      body: try codec.encode(mutation.validated()),
      lease: lease
    )
  }

  public func eventRecords(
    after cursor: GatewayEventCursor,
    lease: GatewayTransportConnectionLease
  ) async throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error> {
    let state = try requireConnected(lease: lease)
    let subscriptionID = GatewayXPCSubscriptionID()
    let subscriptionEnvelope: GatewayXPCRequestEnvelope
    do {
      let body = try codec.encode(cursor)
      subscriptionEnvelope = GatewayXPCRequestEnvelope(
        operation: .subscribeEvents,
        lease: lease,
        sessionID: state.sessionID,
        subscriptionID: subscriptionID,
        body: body
      )
    } catch {
      throw codec.canonicalFailure(from: error)
    }

    let subscription: GatewayXPCEventSubscription
    do {
      let rawEnvelope = try encodeEnvelope(subscriptionEnvelope)
      subscription = try await state.connection.subscribe(
        rawEnvelope,
        bufferCapacity: configuration.subscriberBufferCapacity
      )
      try requireCurrentConnection(state)
      guard subscription.id == subscriptionID else {
        await subscription.cancel()
        throw GatewayFailure(
          code: .malformedPayload,
          message: "The XPC connection returned a different subscription identity."
        )
      }
    } catch {
      throw codec.canonicalFailure(from: error)
    }

    let pair = AsyncThrowingStream<GatewayEventEnvelope, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(configuration.subscriberBufferCapacity)
    )
    let continuation = pair.continuation
    let upstream = subscription.stream
    let codec = self.codec
    let generation = state.generation
    let stateLease = state.lease
    let task = Task {
      var shouldCancelSubscription = true
      do {
        for try await rawEvent in upstream {
          guard self.isCurrentConnection(generation: generation, lease: stateLease) else {
            throw GatewayFailure(
              code: .supersededOperation,
              message: "The gateway event subscription was superseded by a newer connection."
            )
          }
          let envelope = try codec.decode(GatewayEventEnvelope.self, from: rawEvent)
          switch continuation.yield(envelope) {
          case .enqueued:
            continue
          case .dropped, .terminated:
            continuation.finish(
              throwing: GatewayFailure(
                code: .consumerTooSlow,
                message: "The XPC event consumer fell behind its bounded buffer.",
                isRetryable: true
              )
            )
            await subscription.cancel()
            return
          @unknown default:
            continuation.finish(
              throwing: GatewayFailure(
                code: .consumerTooSlow,
                message: "The XPC event stream could not enqueue a record.",
                isRetryable: true
              )
            )
            await subscription.cancel()
            return
          }
        }
        continuation.finish()
        shouldCancelSubscription = false
      } catch is CancellationError {
        continuation.finish(throwing: CancellationError())
      } catch {
        continuation.finish(throwing: codec.canonicalFailure(from: error))
      }
      if shouldCancelSubscription {
        await subscription.cancel()
      }
    }
    continuation.onTermination = { @Sendable termination in
      task.cancel()
      guard case .cancelled = termination else {
        return
      }
      Task {
        await subscription.cancel()
      }
    }
    return pair.stream
  }

  public func disconnect(lease: GatewayTransportConnectionLease) async {
    if let pendingHandshake, pendingHandshake.lease == lease {
      self.pendingHandshake = nil
      await pendingHandshake.connection.invalidate()
    }

    guard let connected, connected.lease == lease else {
      return
    }
    self.connected = nil

    if let body = try? codec.encode(Data()),
      let rawEnvelope = try? encodeEnvelope(
        GatewayXPCRequestEnvelope(
          operation: .disconnect,
          lease: lease,
          sessionID: connected.sessionID,
          body: body
        )
      )
    {
      _ = try? await connected.connection.request(rawEnvelope)
    }
    await connected.connection.invalidate()
  }

  private func encodeEnvelope(_ envelope: GatewayXPCRequestEnvelope) throws -> Data {
    try codec.encode(envelope)
  }

  private func decodeResponse<Value: Codable & Sendable>(
    _ data: Data,
    operation: GatewayXPCOperation,
    as type: Value.Type
  ) throws -> Value {
    let response = try codec.decode(GatewayXPCResponseEnvelope.self, from: data)
    let validated = try response.validated()
    guard validated.operation == operation else {
      throw GatewayFailure(
        code: .malformedPayload,
        message: "The gateway XPC reply operation did not match the request."
      )
    }
    if let failure = validated.failure {
      throw codec.canonicalFailure(from: failure)
    }
    guard let body = validated.body else {
      throw GatewayFailure(
        code: .malformedPayload,
        message: "The gateway XPC reply did not contain a result."
      )
    }
    return try codec.decode(type, from: body)
  }

  private func validateEmptyResponse(
    _ data: Data,
    operation: GatewayXPCOperation
  ) throws {
    let response = try codec.decode(GatewayXPCResponseEnvelope.self, from: data).validated()
    guard response.operation == operation else {
      throw GatewayFailure(
        code: .malformedPayload,
        message: "The gateway XPC reply operation did not match the request."
      )
    }
    if let failure = response.failure {
      throw codec.canonicalFailure(from: failure)
    }
    guard response.body == nil else {
      throw GatewayFailure(
        code: .malformedPayload,
        message: "The gateway XPC reply unexpectedly contained a result."
      )
    }
  }

  private func residentControlResponse(
    operation: GatewayXPCOperation,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayResidentStatus {
    let state = try requireConnected(lease: lease)
    do {
      try Task.checkCancellation()
      let envelope = try encodeEnvelope(
        GatewayXPCRequestEnvelope(
          operation: operation,
          lease: lease,
          sessionID: state.sessionID,
          body: Data()
        )
      )
      let rawResponse = try await state.connection.request(envelope)
      try requireCurrentConnection(state)
      return try decodeResponse(
        rawResponse,
        operation: operation,
        as: GatewayResidentStatus.self
      )
    } catch {
      throw codec.canonicalFailure(from: error)
    }
  }

  private func residentHeartbeatResponse(
    operation: GatewayXPCOperation,
    body: Data,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayHeartbeatScheduleList {
    let state = try requireConnected(lease: lease)
    do {
      try Task.checkCancellation()
      let envelope = try encodeEnvelope(
        GatewayXPCRequestEnvelope(
          operation: operation,
          lease: lease,
          sessionID: state.sessionID,
          body: body
        )
      )
      let rawResponse = try await state.connection.request(envelope)
      try requireCurrentConnection(state)
      return try decodeResponse(
        rawResponse,
        operation: operation,
        as: GatewayHeartbeatScheduleList.self
      ).validated()
    } catch {
      throw codec.canonicalFailure(from: error)
    }
  }

  private func requireConnected(
    lease: GatewayTransportConnectionLease
  ) throws -> ConnectionState {
    guard let connected, connected.lease == lease else {
      throw GatewayFailure(
        code: .notConnected,
        message: "The XPC gateway transport lease is not connected.",
        isRetryable: true
      )
    }
    return connected
  }

  private func requireCurrentHandshake(
    attemptID: UUID,
    lease: GatewayTransportConnectionLease
  ) throws {
    guard let pendingHandshake,
      pendingHandshake.attemptID == attemptID,
      pendingHandshake.lease == lease
    else {
      throw GatewayFailure(
        code: .supersededOperation,
        message: "The XPC gateway handshake was superseded."
      )
    }
  }

  private func requireCurrentConnection(_ state: ConnectionState) throws {
    guard connected?.generation == state.generation,
      connected?.lease == state.lease
    else {
      throw GatewayFailure(
        code: .supersededOperation,
        message: "The XPC gateway operation was superseded by a newer connection."
      )
    }
  }

  private func isCurrentConnection(
    generation: UUID,
    lease: GatewayTransportConnectionLease
  ) -> Bool {
    connected?.generation == generation && connected?.lease == lease
  }
}
