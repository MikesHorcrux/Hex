import Foundation
import HexCore

/// App-facing HexGatewayTransport backed by a fresh local XPC connection per handshake. The
/// transport owns no gateway state: the connection factory and the Data-only XPC endpoint are
/// injected, which keeps lifecycle tests independent of launchd and Mach-service registration.
public actor XPCGatewayTransport: HexGatewayTransport, HexGatewayAuthorizationDecisionTransport,
  HexGatewayResidentControlTransport, HexGatewayAccessibilityPermissionTransport,
  HexGatewayScreenControlPermissionTransport, HexGatewayModelCatalogTransport,
  HexGatewayTaskTransport, HexGatewayConversationTransport, HexGatewayProcessSessionTransport,
  HexGatewayRunRecoveryTransport,
  HexGatewayArtifactReadTransport,
  HexGatewayToolServerControlTransport, HexGatewayPermissionManagementTransport
{

  private let connectionFactory: any HexGatewayXPCConnectionFactory
  private let configuration: GatewayConfiguration
  private let codec: GatewayWireCodec
  private var connected: XPCGatewayTransportConnectionState?
  private var pendingHandshake: XPCGatewayTransportHandshakeState?

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
    pendingHandshake = XPCGatewayTransportHandshakeState(
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
      connected = XPCGatewayTransportConnectionState(
        generation: UUID(),
        lease: lease,
        sessionID: response.sessionID,
        selectedVersion: response.selectedVersion,
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

  public func recoverRun(
    _ request: GatewayRunRecoveryRequest, lease: GatewayTransportConnectionLease
  ) async throws -> GatewayRunRecoveryResponse {
    try await recoveryRequest(
      request, operation: .recoverRun, lease: lease, response: GatewayRunRecoveryResponse.self)
  }

  public func taskOperation(_ request: GatewayTaskRequest, lease: GatewayTransportConnectionLease)
    async throws -> GatewayTaskResponse
  {
    try await recoveryRequest(
      request, operation: .taskOperation, lease: lease,
      response: GatewayTaskResponse.self)
  }

  public func processSession(
    _ request: GatewayProcessSessionRequest, lease: GatewayTransportConnectionLease
  )
    async throws -> GatewayProcessSessionResponse
  {
    try await recoveryRequest(
      request, operation: .processSession, lease: lease,
      response: GatewayProcessSessionResponse.self)
  }

  public func conversationStorage(
    _ request: ConversationStorageRequest,
    lease: GatewayTransportConnectionLease
  ) async throws -> ConversationStorageResponse {
    try await recoveryRequest(
      request, operation: .conversationStorage, lease: lease,
      response: ConversationStorageResponse.self)
  }

  public func readRunHistory(
    _ request: GatewayRunHistoryRequest, lease: GatewayTransportConnectionLease
  ) async throws -> GatewayRunHistoryPage {
    try await recoveryRequest(
      request, operation: .readRunHistory, lease: lease, response: GatewayRunHistoryPage.self)
  }

  private func recoveryRequest<Request: Encodable & Sendable, Response: Codable & Sendable>(
    _ request: Request, operation: GatewayXPCOperation, lease: GatewayTransportConnectionLease,
    response: Response.Type
  ) async throws -> Response {
    try Task.checkCancellation()
    let state = try requireConnected(lease: lease)
    do {
      let body = try codec.encode(request)
      let envelope = try encodeEnvelope(
        GatewayXPCRequestEnvelope(
          operation: operation, lease: lease, sessionID: state.sessionID, body: body))
      let raw = try await state.connection.request(envelope)
      try Task.checkCancellation()
      try requireCurrentConnection(state)
      return try decodeResponse(raw, operation: operation, as: response)
    } catch is CancellationError { throw CancellationError() } catch {
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

  public func accessibilityPermissionStatus(
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayAccessibilityPermissionStatus {
    try await accessibilityPermissionResponse(
      operation: .accessibilityPermissionStatus,
      lease: lease
    )
  }

  public func requestAccessibilityPermission(
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayAccessibilityPermissionStatus {
    try await accessibilityPermissionResponse(
      operation: .requestAccessibilityPermission,
      lease: lease
    )
  }

  public func screenControlPermissionStatus(
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayScreenControlPermissionStatus {
    try await screenControlPermissionResponse(
      operation: .screenControlPermissionStatus,
      lease: lease
    )
  }

  public func availableModels(lease: GatewayTransportConnectionLease) async throws
    -> [ModelDescriptor]
  {
    let state = try requireConnected(lease: lease)
    do {
      try Task.checkCancellation()
      let envelope = try encodeEnvelope(
        GatewayXPCRequestEnvelope(
          operation: .availableModels, lease: lease, sessionID: state.sessionID, body: Data()
        ))
      let rawResponse = try await state.connection.request(envelope)
      try requireCurrentConnection(state)
      return try decodeResponse(
        rawResponse, operation: .availableModels, as: [ModelDescriptor].self)
    } catch {
      throw codec.canonicalFailure(from: error)
    }
  }

  public func toolServerHealth(lease: GatewayTransportConnectionLease) async throws
    -> GatewayToolServerHealth
  {
    try await toolServerResponse(
      operation: .toolServerHealth, body: Data(), lease: lease,
      as: GatewayToolServerHealth.self
    ).validated()
  }

  public func refreshToolServer(
    _ request: GatewayToolServerRequest, lease: GatewayTransportConnectionLease
  ) async throws -> GatewayToolServerStatus {
    let request = try request.validated()
    return try await toolServerResponse(
      operation: .refreshToolServer, body: codec.encode(request), lease: lease,
      as: GatewayToolServerStatus.self
    ).validated(for: request)
  }

  private func toolServerResponse<Response: Codable & Sendable>(
    operation: GatewayXPCOperation, body: Data, lease: GatewayTransportConnectionLease,
    as responseType: Response.Type
  ) async throws -> Response {
    try Task.checkCancellation()
    let state = try requireConnected(lease: lease)
    guard state.selectedVersion >= GatewayProtocolVersion(major: 1, minor: 13) else {
      throw GatewayFailure(
        code: .transportUnavailable,
        message: "Tool server controls require an updated resident agent.")
    }
    do {
      let envelope = try encodeEnvelope(
        GatewayXPCRequestEnvelope(
          operation: operation, lease: lease, sessionID: state.sessionID, body: body))
      let raw = try await state.connection.request(envelope)
      try Task.checkCancellation()
      try requireCurrentConnection(state)
      return try decodeResponse(raw, operation: operation, as: responseType)
    } catch is CancellationError { throw CancellationError() } catch {
      try requireCurrentConnection(state)
      throw codec.canonicalFailure(from: error)
    }
  }

  public func readArtifact(
    _ request: GatewayArtifactReadRequest, lease: GatewayTransportConnectionLease
  ) async throws -> GatewayArtifactReadResponse {
    try Task.checkCancellation()
    try GatewayArtifactReadValidation.request(request)
    let state = try requireConnected(lease: lease)
    do {
      let envelope = try encodeEnvelope(
        GatewayXPCRequestEnvelope(
          operation: .readArtifact, lease: lease, sessionID: state.sessionID,
          body: codec.encode(request)))
      let rawResponse = try await state.connection.request(envelope)
      try Task.checkCancellation()
      try requireCurrentConnection(state)
      let response = try decodeResponse(
        rawResponse, operation: .readArtifact, as: GatewayArtifactReadResponse.self)
      try GatewayArtifactReadValidation.response(response, request: request)
      return response
    } catch is CancellationError { throw CancellationError() } catch {
      try requireCurrentConnection(state)
      throw codec.canonicalFailure(from: error)
    }
  }

  public func requestScreenControlPermission(
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayScreenControlPermissionStatus {
    try await screenControlPermissionResponse(
      operation: .requestScreenControlPermission,
      lease: lease
    )
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

  public func listHeartbeatRuns(
    _ request: GatewayHeartbeatRunListRequest, lease: GatewayTransportConnectionLease
  ) async throws -> GatewayHeartbeatRunPage {
    let request = try request.validated()
    return try await recoveryRequest(
      request, operation: .listHeartbeatRuns, lease: lease,
      response: GatewayHeartbeatRunPage.self
    ).validated(for: request)
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

    let pair = GatewayBufferedStream<GatewayEventEnvelope>.makeStream(
      bufferCapacity: configuration.subscriberBufferCapacity,
      maximumBufferedBytes: configuration.maximumBufferedWireBytesPerSubscriber)
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
          switch continuation.yield(envelope, wireBytes: rawEvent.count) {
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

  public func approvalInbox(lease: GatewayTransportConnectionLease) async throws
    -> GatewayApprovalInbox
  {
    let response: GatewayApprovalInbox = try await permissionResponse(
      operation: .approvalInbox, lease: lease)
    return try response.validated()
  }

  public func revokeSessionGrant(
    _ grant: GatewaySessionGrant, lease: GatewayTransportConnectionLease
  )
    async throws -> GatewayApprovalInbox
  {
    let response: GatewayApprovalInbox = try await permissionResponse(
      operation: .revokeSessionGrant, body: codec.encode(grant.validated()), lease: lease)
    return try response.validated()
  }

  public func folderAccessStatus(lease: GatewayTransportConnectionLease) async throws
    -> GatewayFolderAccessStatus
  {
    let response: GatewayFolderAccessStatus = try await permissionResponse(
      operation: .folderAccessStatus, lease: lease)
    return try response.validated()
  }

  private func permissionResponse<Response: Codable & Sendable>(
    operation: GatewayXPCOperation, body: Data = Data(), lease: GatewayTransportConnectionLease
  ) async throws -> Response {
    let state = try requireConnected(lease: lease)
    try Task.checkCancellation()
    let envelope = try encodeEnvelope(
      GatewayXPCRequestEnvelope(
        operation: operation, lease: lease, sessionID: state.sessionID, body: body))
    let rawResponse = try await state.connection.request(envelope)
    try Task.checkCancellation()
    try requireCurrentConnection(state)
    return try decodeResponse(rawResponse, operation: operation, as: Response.self)
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

  private func accessibilityPermissionResponse(
    operation: GatewayXPCOperation,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayAccessibilityPermissionStatus {
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
        as: GatewayAccessibilityPermissionStatus.self
      )
    } catch {
      throw codec.canonicalFailure(from: error)
    }
  }

  private func screenControlPermissionResponse(
    operation: GatewayXPCOperation,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayScreenControlPermissionStatus {
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
        as: GatewayScreenControlPermissionStatus.self
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
  ) throws -> XPCGatewayTransportConnectionState {
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

  private func requireCurrentConnection(_ state: XPCGatewayTransportConnectionState) throws {
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
