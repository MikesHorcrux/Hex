@preconcurrency import Foundation
import HexCore

/// Exported-object adapter for a single NSXPCConnection. It translates bounded Data envelopes into
/// the existing `HexGatewayService` API and owns the connection's lease, session, and subscriptions.
/// A listener should create one instance per accepted NSXPCConnection and call `invalidate()` from
/// that connection's invalidation handler.
public final class HexGatewayXPCService: NSObject, HexGatewayXPCServiceProtocol {
  private actor State {
    private let service: HexGatewayService
    private let codec: GatewayWireCodec
    private let authorizationDecisionHandler:
      (
        @Sendable (
          AuthorizationRequest,
          GatewayAuthorizationDecisionChoice,
          HexGatewayAuthorizationCommitGate
        ) async throws -> Void
      )?
    private let residentControlHandlers: HexGatewayResidentControlHandlers
    private let accessibilityPermissionHandlers: HexGatewayAccessibilityPermissionHandlers
    private var activeLease: GatewayTransportConnectionLease?
    private var sessionID: GatewaySessionID?
    private var subscriptions: [GatewayXPCSubscriptionID: Task<Void, Never>] = [:]
    private var authorizationCommitGate: HexGatewayAuthorizationCommitGate

    init(
      service: HexGatewayService,
      configuration: GatewayConfiguration,
      authorizationDecisionHandler:
        (
          @Sendable (
            AuthorizationRequest,
            GatewayAuthorizationDecisionChoice,
            HexGatewayAuthorizationCommitGate
          ) async throws -> Void
        )?,
      residentControlHandlers: HexGatewayResidentControlHandlers,
      accessibilityPermissionHandlers: HexGatewayAccessibilityPermissionHandlers
    ) {
      self.service = service
      codec = GatewayWireCodec(configuration: configuration)
      self.authorizationDecisionHandler = authorizationDecisionHandler
      self.residentControlHandlers = residentControlHandlers
      self.accessibilityPermissionHandlers = accessibilityPermissionHandlers
      authorizationCommitGate = HexGatewayAuthorizationCommitGate()
    }

    func request(_ rawEnvelope: Data) async -> Data {
      var operation = GatewayXPCOperation.handshake
      do {
        let envelope = try codec.decode(GatewayXPCRequestEnvelope.self, from: rawEnvelope)
        operation = envelope.operation
        guard envelope.operation != .subscribeEvents else {
          throw GatewayFailure(
            code: .malformedPayload,
            message: "Event subscriptions must use the XPC subscription method."
          )
        }
        return try await handle(envelope)
      } catch {
        return failureResponse(operation: operation, error: error)
      }
    }

    func subscribe(
      _ rawEnvelope: Data,
      sink: GatewayXPCEventSinkBridge
    ) async -> Data {
      do {
        let envelope = try codec.decode(GatewayXPCRequestEnvelope.self, from: rawEnvelope)
        guard envelope.operation == .subscribeEvents,
          let subscriptionID = envelope.subscriptionID
        else {
          throw GatewayFailure(
            code: .malformedPayload,
            message: "The XPC subscription envelope is malformed."
          )
        }
        try validateLease(envelope.lease)
        try requireSession(for: envelope)
        guard subscriptions[subscriptionID] == nil else {
          throw GatewayFailure(
            code: .conflictingRunRequest,
            message: "The XPC subscription identifier is already active."
          )
        }
        let cursor = try codec.decode(GatewayEventCursor.self, from: envelope.body)
        let sessionID = try currentSession(for: envelope)
        let stream = try await service.eventRecords(
          after: cursor,
          sessionID: sessionID
        )
        let codec = self.codec
        let task = Task { [weak self, codec] in
          do {
            for try await event in stream {
              guard !Task.isCancelled else {
                return
              }
              let data = try codec.encode(event)
              await sink.receiveEvent(data)
            }
            guard !Task.isCancelled else {
              return
            }
            let completion = try codec.encode(
              GatewayXPCResponseEnvelope(
                operation: .subscribeEvents,
                body: nil
              )
            )
            await sink.finish(completion)
          } catch is CancellationError {
            return
          } catch {
            guard !Task.isCancelled else {
              return
            }
            let completion =
              (try? codec.encode(
                GatewayXPCResponseEnvelope(
                  operation: .subscribeEvents,
                  failure: codec.canonicalFailure(from: error)
                )
              )) ?? Data()
            await sink.finish(completion)
          }
          await self?.subscriptionFinished(subscriptionID)
        }
        subscriptions[subscriptionID] = task
        return try successResponse(
          operation: .subscribeEvents,
          body: nil
        )
      } catch {
        return failureResponse(operation: .subscribeEvents, error: error)
      }
    }

    func invalidate() async {
      authorizationCommitGate.invalidate()
      let tasks = subscriptions.values
      subscriptions.removeAll()
      for task in tasks {
        task.cancel()
      }
      if let sessionID {
        await service.disconnect(sessionID: sessionID)
      }
      activeLease = nil
      sessionID = nil
    }

    private func handle(_ envelope: GatewayXPCRequestEnvelope) async throws -> Data {
      try validateEnvelopeShape(envelope)
      switch envelope.operation {
      case .handshake:
        let request = try codec.decode(GatewayHandshakeRequest.self, from: envelope.body)
        await disconnectActiveSession()
        let response = try await service.handshake(request)
        activeLease = envelope.lease
        sessionID = response.sessionID
        return try successResponse(operation: .handshake, value: response)

      case .startRun:
        let sessionID = try currentSession(for: envelope)
        let request = try codec.decode(GatewayStartRunRequest.self, from: envelope.body)
        let response = try await service.startRun(request, sessionID: sessionID)
        return try successResponse(operation: .startRun, value: response)

      case .cancelRun:
        let sessionID = try currentSession(for: envelope)
        let request = try codec.decode(GatewayCancelRunRequest.self, from: envelope.body)
        let response = try await service.cancelRun(request, sessionID: sessionID)
        return try successResponse(operation: .cancelRun, value: response)

      case .submitAuthorizationDecision:
        _ = try currentSession(for: envelope)
        guard let authorizationDecisionHandler else {
          throw GatewayFailure(
            code: .transportUnavailable,
            message: "The resident gateway has no authorization decision handler."
          )
        }
        let decision = try codec.decode(
          GatewayAuthorizationDecisionRequest.self,
          from: envelope.body
        )
        try await authorizationDecisionHandler(
          decision.request,
          decision.choice,
          authorizationCommitGate
        )
        return try successResponse(
          operation: .submitAuthorizationDecision,
          body: nil
        )

      case .accessibilityPermissionStatus:
        _ = try currentSession(for: envelope)
        try requireEmptyBody(for: envelope)
        guard let handler = accessibilityPermissionHandlers.status else {
          throw GatewayFailure(
            code: .transportUnavailable,
            message: "The resident gateway does not expose Accessibility permission status."
          )
        }
        let status = try await handler()
        _ = try currentSession(for: envelope)
        return try successResponse(operation: .accessibilityPermissionStatus, value: status)

      case .requestAccessibilityPermission:
        _ = try currentSession(for: envelope)
        try requireEmptyBody(for: envelope)
        guard let handler = accessibilityPermissionHandlers.request else {
          throw GatewayFailure(
            code: .transportUnavailable,
            message: "The resident gateway does not expose Accessibility permission requests."
          )
        }
        let status = try await handler()
        _ = try currentSession(for: envelope)
        return try successResponse(operation: .requestAccessibilityPermission, value: status)

      case .status:
        _ = try currentSession(for: envelope)
        try requireEmptyBody(for: envelope)
        let status: GatewayResidentStatus
        if let handler = residentControlHandlers.status {
          status = try await handler()
        } else {
          status = .unavailable
        }
        _ = try currentSession(for: envelope)
        return try successResponse(operation: .status, value: status)

      case .pauseHeartbeats:
        _ = try currentSession(for: envelope)
        try requireEmptyBody(for: envelope)
        guard let handler = residentControlHandlers.pauseHeartbeats else {
          throw GatewayFailure(
            code: .transportUnavailable,
            message: "The resident gateway does not expose heartbeat controls."
          )
        }
        let status = try await handler()
        _ = try currentSession(for: envelope)
        return try successResponse(operation: .pauseHeartbeats, value: status)

      case .resumeHeartbeats:
        _ = try currentSession(for: envelope)
        try requireEmptyBody(for: envelope)
        guard let handler = residentControlHandlers.resumeHeartbeats else {
          throw GatewayFailure(
            code: .transportUnavailable,
            message: "The resident gateway does not expose heartbeat controls."
          )
        }
        let status = try await handler()
        _ = try currentSession(for: envelope)
        return try successResponse(operation: .resumeHeartbeats, value: status)

      case .listHeartbeats:
        _ = try currentSession(for: envelope)
        try requireEmptyBody(for: envelope)
        guard let handler = residentControlHandlers.listHeartbeats else {
          throw GatewayFailure(
            code: .transportUnavailable,
            message: "The resident gateway does not expose heartbeat schedule management."
          )
        }
        let schedules = try await handler()
        _ = try schedules.validated()
        _ = try currentSession(for: envelope)
        return try successResponse(operation: .listHeartbeats, value: schedules)

      case .addHeartbeat:
        _ = try currentSession(for: envelope)
        guard let handler = residentControlHandlers.addHeartbeat else {
          throw GatewayFailure(
            code: .transportUnavailable,
            message: "The resident gateway does not expose heartbeat schedule management."
          )
        }
        let request = try codec.decode(GatewayHeartbeatScheduleRequest.self, from: envelope.body)
        let schedules = try await handler(try request.validated())
        _ = try schedules.validated()
        _ = try currentSession(for: envelope)
        return try successResponse(operation: .addHeartbeat, value: schedules)

      case .removeHeartbeat:
        _ = try currentSession(for: envelope)
        guard let handler = residentControlHandlers.removeHeartbeat else {
          throw GatewayFailure(
            code: .transportUnavailable,
            message: "The resident gateway does not expose heartbeat schedule management."
          )
        }
        let mutation = try codec.decode(GatewayHeartbeatScheduleMutation.self, from: envelope.body)
        let schedules = try await handler(try mutation.validated())
        _ = try schedules.validated()
        _ = try currentSession(for: envelope)
        return try successResponse(operation: .removeHeartbeat, value: schedules)

      case .pauseHeartbeat:
        _ = try currentSession(for: envelope)
        guard let handler = residentControlHandlers.pauseHeartbeat else {
          throw GatewayFailure(
            code: .transportUnavailable,
            message: "The resident gateway does not expose heartbeat schedule management."
          )
        }
        let mutation = try codec.decode(GatewayHeartbeatScheduleMutation.self, from: envelope.body)
        let schedules = try await handler(try mutation.validated())
        _ = try schedules.validated()
        _ = try currentSession(for: envelope)
        return try successResponse(operation: .pauseHeartbeat, value: schedules)

      case .resumeHeartbeat:
        _ = try currentSession(for: envelope)
        guard let handler = residentControlHandlers.resumeHeartbeat else {
          throw GatewayFailure(
            code: .transportUnavailable,
            message: "The resident gateway does not expose heartbeat schedule management."
          )
        }
        let mutation = try codec.decode(GatewayHeartbeatScheduleMutation.self, from: envelope.body)
        let schedules = try await handler(try mutation.validated())
        _ = try schedules.validated()
        _ = try currentSession(for: envelope)
        return try successResponse(operation: .resumeHeartbeat, value: schedules)

      case .cancelSubscription:
        _ = try currentSession(for: envelope)
        guard let subscriptionID = envelope.subscriptionID else {
          throw GatewayFailure(
            code: .malformedPayload,
            message: "The XPC cancellation envelope is missing its subscription identity."
          )
        }
        subscriptions.removeValue(forKey: subscriptionID)?.cancel()
        return try successResponse(operation: .cancelSubscription, body: nil)

      case .disconnect:
        _ = try currentSession(for: envelope)
        await invalidate()
        return try successResponse(operation: .disconnect, body: nil)

      case .subscribeEvents:
        throw GatewayFailure(
          code: .malformedPayload,
          message: "Event subscriptions must use the XPC subscription method."
        )
      }
    }

    private func validateEnvelopeShape(_ envelope: GatewayXPCRequestEnvelope) throws {
      try validateLease(envelope.lease)
      switch envelope.operation {
      case .handshake:
        guard envelope.sessionID == nil, envelope.subscriptionID == nil else {
          throw GatewayFailure(
            code: .malformedPayload,
            message: "The XPC handshake envelope contains connection-only fields."
          )
        }
      case .startRun, .cancelRun, .submitAuthorizationDecision, .accessibilityPermissionStatus,
        .requestAccessibilityPermission, .status, .pauseHeartbeats, .resumeHeartbeats,
        .listHeartbeats, .addHeartbeat, .removeHeartbeat, .pauseHeartbeat, .resumeHeartbeat,
        .disconnect:
        guard envelope.sessionID != nil, envelope.subscriptionID == nil else {
          throw GatewayFailure(
            code: .malformedPayload,
            message: "The XPC request envelope has invalid connection fields."
          )
        }
      case .cancelSubscription:
        guard envelope.sessionID != nil, envelope.subscriptionID != nil else {
          throw GatewayFailure(
            code: .malformedPayload,
            message: "The XPC cancellation envelope has invalid connection fields."
          )
        }
      case .subscribeEvents:
        break
      }
    }

    private func requireSession(for envelope: GatewayXPCRequestEnvelope) throws {
      guard let activeLease, activeLease == envelope.lease else {
        throw GatewayFailure(
          code: .notConnected,
          message: "The XPC request lease is not connected.",
          isRetryable: true
        )
      }
      guard let currentSession = sessionID,
        envelope.sessionID == currentSession
      else {
        throw GatewayFailure(
          code: .staleSession,
          message: "The XPC request session is missing or stale.",
          isRetryable: true
        )
      }
    }

    private func currentSession(for envelope: GatewayXPCRequestEnvelope) throws -> GatewaySessionID
    {
      try requireSession(for: envelope)
      guard let sessionID else {
        throw GatewayFailure(
          code: .staleSession,
          message: "The XPC gateway session is unavailable.",
          isRetryable: true
        )
      }
      return sessionID
    }

    private func disconnectActiveSession() async {
      authorizationCommitGate.invalidate()
      authorizationCommitGate = HexGatewayAuthorizationCommitGate()
      if let sessionID {
        await service.disconnect(sessionID: sessionID)
      }
      let tasks = subscriptions.values
      subscriptions.removeAll()
      for task in tasks {
        task.cancel()
      }
      activeLease = nil
      sessionID = nil
    }

    private func subscriptionFinished(_ subscriptionID: GatewayXPCSubscriptionID) {
      subscriptions.removeValue(forKey: subscriptionID)
    }

    private func validateLease(_ lease: GatewayTransportConnectionLease) throws {
      guard !isZero(lease.rawValue) else {
        throw GatewayFailure(
          code: .malformedPayload,
          message: "The XPC request contains an invalid lease identity."
        )
      }
    }

    private func successResponse<Value: Codable & Sendable>(
      operation: GatewayXPCOperation,
      value: Value
    ) throws -> Data {
      try successResponse(operation: operation, body: codec.encode(value))
    }

    private func successResponse(
      operation: GatewayXPCOperation,
      body: Data?
    ) throws -> Data {
      try codec.encode(
        GatewayXPCResponseEnvelope(operation: operation, body: body)
      )
    }

    private func requireEmptyBody(for envelope: GatewayXPCRequestEnvelope) throws {
      guard envelope.body.isEmpty else {
        throw GatewayFailure(
          code: .malformedPayload,
          message: "The resident gateway control request must not contain a body."
        )
      }
    }

    private func failureResponse(
      operation: GatewayXPCOperation,
      error: any Error
    ) -> Data {
      let response = GatewayXPCResponseEnvelope(
        operation: operation,
        failure: codec.canonicalFailure(from: error)
      )
      return (try? codec.encode(response)) ?? Data()
    }

    private func isZero(_ value: UUID) -> Bool {
      value == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }
  }

  private let state: State

  public init(
    service: HexGatewayService,
    configuration: GatewayConfiguration = .standard,
    residentControlHandlers: HexGatewayResidentControlHandlers = .unavailable,
    accessibilityPermissionHandlers: HexGatewayAccessibilityPermissionHandlers = .unavailable
  ) {
    state = State(
      service: service,
      configuration: configuration,
      authorizationDecisionHandler: nil,
      residentControlHandlers: residentControlHandlers,
      accessibilityPermissionHandlers: accessibilityPermissionHandlers
    )
    super.init()
  }

  /// Creates an exported service with a handler owned by the resident composition root. The
  /// handler receives the complete request echoed by the app and the active connection's commit
  /// gate; it must pass that gate to the broker so invalidation cannot race the final commit.
  public init(
    service: HexGatewayService,
    configuration: GatewayConfiguration = .standard,
    authorizationDecisionHandler:
      @escaping @Sendable (
        AuthorizationRequest,
        GatewayAuthorizationDecisionChoice,
        HexGatewayAuthorizationCommitGate
      ) async throws -> Void,
    residentControlHandlers: HexGatewayResidentControlHandlers = .unavailable,
    accessibilityPermissionHandlers: HexGatewayAccessibilityPermissionHandlers = .unavailable
  ) {
    state = State(
      service: service,
      configuration: configuration,
      authorizationDecisionHandler: authorizationDecisionHandler,
      residentControlHandlers: residentControlHandlers,
      accessibilityPermissionHandlers: accessibilityPermissionHandlers
    )
    super.init()
  }

  /// Configures both the exported and imported XPC interfaces for this Data-only protocol.
  public static func interface() -> NSXPCInterface {
    let interface = NSXPCInterface(with: HexGatewayXPCServiceProtocol.self)
    let eventSinkInterface = NSXPCInterface(with: HexGatewayXPCEventSinkProtocol.self)
    interface.setInterface(
      eventSinkInterface,
      for: NSSelectorFromString("subscribe:sink:withReply:"),
      argumentIndex: 1,
      ofReply: false
    )
    return interface
  }

  /// Call this from the NSXPCConnection invalidation handler. It is safe to call more than once.
  public func invalidate() {
    let state = self.state
    Task {
      await state.invalidate()
    }
  }

  public func request(_ envelope: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
    let state = self.state
    Task {
      reply(await state.request(envelope))
    }
  }

  public func subscribe(
    _ envelope: Data,
    sink: HexGatewayXPCEventSinkProtocol,
    withReply reply: @escaping @Sendable (Data) -> Void
  ) {
    let bridge = GatewayXPCEventSinkBridge(sink: sink)
    let state = self.state
    Task {
      reply(await state.subscribe(envelope, sink: bridge))
    }
  }
}
