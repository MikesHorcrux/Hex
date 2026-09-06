import Foundation
import HexCore

/// A bounded loopback transport for local development and deterministic tests. Both endpoints remain
/// in one process. It does not launch `HexGateway`, survive app termination, provide XPC isolation, or
/// expand the app's sandbox, filesystem, terminal, privacy, or network privileges.
/// Its configuration bounds client-side encoding and forwarding; the service independently enforces
/// its own envelope, so a larger transport configuration never weakens service admission.
public actor InProcessHexGatewayTransport: HexGatewayTransport, HexGatewayRunRecoveryTransport,
  HexGatewayArtifactReadTransport, HexGatewayResidentControlTransport,
  HexGatewayToolServerControlTransport
{
  private let service: HexGatewayService
  private let configuration: GatewayConfiguration
  private let codec: GatewayWireCodec
  private let residentControlHandlers: HexGatewayResidentControlHandlers
  private let toolServerControlHandlers: HexGatewayToolServerControlHandlers
  private var selectedProtocolVersion: GatewayProtocolVersion?
  private var sessionID: GatewaySessionID?
  private var connectedLease: GatewayTransportConnectionLease?
  private var latestHandshakeAttemptID: UUID?
  private var latestHandshakeLease: GatewayTransportConnectionLease?

  public init(
    service: HexGatewayService,
    configuration: GatewayConfiguration = .standard,
    residentControlHandlers: HexGatewayResidentControlHandlers = .unavailable
  ) {
    self.init(
      service: service, configuration: configuration,
      residentControlHandlers: residentControlHandlers,
      toolServerControlHandlers: .unavailable)
  }

  public init(
    service: HexGatewayService,
    configuration: GatewayConfiguration = .standard,
    residentControlHandlers: HexGatewayResidentControlHandlers = .unavailable,
    toolServerControlHandlers: HexGatewayToolServerControlHandlers
  ) {
    self.service = service
    self.configuration = configuration
    self.residentControlHandlers = residentControlHandlers
    self.toolServerControlHandlers = toolServerControlHandlers
    codec = GatewayWireCodec(configuration: configuration)
  }

  public func handshake(
    _ request: GatewayHandshakeRequest,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayHandshakeResponse {
    let attemptID = UUID()
    latestHandshakeAttemptID = attemptID
    latestHandshakeLease = lease
    if let sessionID {
      self.sessionID = nil
      connectedLease = nil
      await service.disconnect(sessionID: sessionID)
    }

    do {
      guard latestHandshakeAttemptID == attemptID, latestHandshakeLease == lease else {
        throw supersededHandshakeFailure()
      }
      let wireRequest = try codec.roundTrip(request)
      let response = try await service.handshake(wireRequest)

      let wireResponse: GatewayHandshakeResponse
      do {
        wireResponse = try codec.roundTrip(response)
      } catch {
        await service.disconnect(sessionID: response.sessionID)
        throw error
      }

      guard latestHandshakeAttemptID == attemptID, latestHandshakeLease == lease else {
        await service.disconnect(sessionID: response.sessionID)
        throw supersededHandshakeFailure()
      }
      sessionID = wireResponse.sessionID
      connectedLease = lease
      selectedProtocolVersion = wireResponse.selectedVersion
      latestHandshakeAttemptID = nil
      latestHandshakeLease = nil
      return wireResponse
    } catch {
      if latestHandshakeAttemptID == attemptID, latestHandshakeLease == lease {
        latestHandshakeAttemptID = nil
        latestHandshakeLease = nil
      }
      throw codec.canonicalFailure(from: error)
    }
  }

  public func startRun(
    _ request: GatewayStartRunRequest,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayStartRunResponse {
    let sessionID = try requireSession(ownedBy: lease)

    do {
      let wireRequest = try codec.roundTrip(request)
      let response = try await service.startRun(wireRequest, sessionID: sessionID)
      return try codec.roundTrip(response)
    } catch {
      throw codec.canonicalFailure(from: error)
    }
  }

  public func recoverRun(
    _ request: GatewayRunRecoveryRequest, lease: GatewayTransportConnectionLease
  ) async throws -> GatewayRunRecoveryResponse {
    let sessionID = try requireSession(ownedBy: lease)
    do {
      let response = try await service.recoverRun(codec.roundTrip(request), sessionID: sessionID)
      try Task.checkCancellation()
      guard try requireSession(ownedBy: lease) == sessionID else {
        throw supersededHandshakeFailure()
      }
      return try codec.roundTrip(response)
    } catch is CancellationError { throw CancellationError() } catch {
      throw codec.canonicalFailure(from: error)
    }
  }

  public func readRunHistory(
    _ request: GatewayRunHistoryRequest, lease: GatewayTransportConnectionLease
  ) async throws -> GatewayRunHistoryPage {
    let sessionID = try requireSession(ownedBy: lease)
    do {
      let response = try await service.readRunHistory(
        codec.roundTrip(request), sessionID: sessionID)
      try Task.checkCancellation()
      guard try requireSession(ownedBy: lease) == sessionID else {
        throw supersededHandshakeFailure()
      }
      return try codec.roundTrip(response)
    } catch is CancellationError { throw CancellationError() } catch {
      throw codec.canonicalFailure(from: error)
    }
  }

  public func cancelRun(
    _ request: GatewayCancelRunRequest,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayCancelRunResponse {
    let sessionID = try requireSession(ownedBy: lease)

    do {
      let wireRequest = try codec.roundTrip(request)
      let response = try await service.cancelRun(wireRequest, sessionID: sessionID)
      return try codec.roundTrip(response)
    } catch {
      throw codec.canonicalFailure(from: error)
    }
  }

  public func status(lease: GatewayTransportConnectionLease) async throws -> GatewayResidentStatus {
    try await residentOperation(lease: lease) {
      guard let handler = self.residentControlHandlers.status else { return .unavailable }
      return try await handler()
    }
  }

  public func toolServerHealth(lease: GatewayTransportConnectionLease) async throws
    -> GatewayToolServerHealth
  {
    _ = try requireSession(ownedBy: lease)
    try requireToolServerControlsVersion()
    return try await residentOperation(lease: lease) {
      guard let handler = self.toolServerControlHandlers.list else {
        throw Self.controlsUnavailable()
      }
      return try await handler().validated()
    }
  }

  public func refreshToolServer(
    _ request: GatewayToolServerRequest, lease: GatewayTransportConnectionLease
  ) async throws -> GatewayToolServerStatus {
    let request = try codec.roundTrip(request).validated()
    let sessionID = try requireSession(ownedBy: lease)
    try requireToolServerControlsVersion()
    return try await residentOperation(lease: lease) {
      guard let handler = self.toolServerControlHandlers.refresh else {
        throw Self.controlsUnavailable()
      }
      return try await self.service.withIdleToolMaintenance(sessionID: sessionID) {
        try await handler(request).validated(for: request)
      }
    }
  }

  private func requireToolServerControlsVersion() throws {
    guard let selectedProtocolVersion,
      selectedProtocolVersion >= GatewayProtocolVersion(major: 1, minor: 13)
    else { throw Self.controlsUnavailable() }
  }

  public func pauseHeartbeats(lease: GatewayTransportConnectionLease) async throws
    -> GatewayResidentStatus
  {
    try await residentOperation(lease: lease) {
      guard let handler = self.residentControlHandlers.pauseHeartbeats else {
        throw Self.controlsUnavailable()
      }
      return try await handler()
    }
  }

  public func resumeHeartbeats(lease: GatewayTransportConnectionLease) async throws
    -> GatewayResidentStatus
  {
    try await residentOperation(lease: lease) {
      guard let handler = self.residentControlHandlers.resumeHeartbeats else {
        throw Self.controlsUnavailable()
      }
      return try await handler()
    }
  }

  public func listHeartbeats(lease: GatewayTransportConnectionLease) async throws
    -> GatewayHeartbeatScheduleList
  {
    try await residentOperation(lease: lease) {
      guard let handler = self.residentControlHandlers.listHeartbeats else {
        throw Self.controlsUnavailable()
      }
      return try await handler().validated()
    }
  }

  public func addHeartbeat(
    _ request: GatewayHeartbeatScheduleRequest, lease: GatewayTransportConnectionLease
  )
    async throws -> GatewayHeartbeatScheduleList
  {
    let request = try codec.roundTrip(request).validated()
    return try await residentOperation(lease: lease) {
      guard let handler = self.residentControlHandlers.addHeartbeat else {
        throw Self.controlsUnavailable()
      }
      return try await handler(request).validated()
    }
  }

  public func removeHeartbeat(
    _ mutation: GatewayHeartbeatScheduleMutation, lease: GatewayTransportConnectionLease
  )
    async throws -> GatewayHeartbeatScheduleList
  {
    let mutation = try codec.roundTrip(mutation).validated()
    return try await residentOperation(lease: lease) {
      guard let handler = self.residentControlHandlers.removeHeartbeat else {
        throw Self.controlsUnavailable()
      }
      return try await handler(mutation).validated()
    }
  }

  public func pauseHeartbeat(
    _ mutation: GatewayHeartbeatScheduleMutation, lease: GatewayTransportConnectionLease
  )
    async throws -> GatewayHeartbeatScheduleList
  {
    let mutation = try codec.roundTrip(mutation).validated()
    return try await residentOperation(lease: lease) {
      guard let handler = self.residentControlHandlers.pauseHeartbeat else {
        throw Self.controlsUnavailable()
      }
      return try await handler(mutation).validated()
    }
  }

  public func resumeHeartbeat(
    _ mutation: GatewayHeartbeatScheduleMutation, lease: GatewayTransportConnectionLease
  )
    async throws -> GatewayHeartbeatScheduleList
  {
    let mutation = try codec.roundTrip(mutation).validated()
    return try await residentOperation(lease: lease) {
      guard let handler = self.residentControlHandlers.resumeHeartbeat else {
        throw Self.controlsUnavailable()
      }
      return try await handler(mutation).validated()
    }
  }

  public func listHeartbeatRuns(
    _ request: GatewayHeartbeatRunListRequest, lease: GatewayTransportConnectionLease
  )
    async throws -> GatewayHeartbeatRunPage
  {
    let request = try codec.roundTrip(request).validated()
    return try await residentOperation(lease: lease) {
      guard let handler = self.residentControlHandlers.listHeartbeatRuns else {
        throw Self.controlsUnavailable()
      }
      let page = try await handler(request).validated(for: request)
      _ = try self.codec.encode(
        GatewayXPCResponseEnvelope(
          operation: .listHeartbeatRuns,
          body: self.codec.encode(page)))
      return page
    }
  }

  private func residentOperation<Response: Codable & Sendable>(
    lease: GatewayTransportConnectionLease, operation: @Sendable () async throws -> Response
  ) async throws -> Response {
    try Task.checkCancellation()
    let sessionID = try requireSession(ownedBy: lease)
    try await service.requireSession(sessionID)
    try Task.checkCancellation()
    guard try requireSession(ownedBy: lease) == sessionID else {
      throw supersededHandshakeFailure()
    }
    do {
      let response = try await operation()
      try Task.checkCancellation()
      guard try requireSession(ownedBy: lease) == sessionID else {
        throw supersededHandshakeFailure()
      }
      try await service.requireSession(sessionID)
      guard try requireSession(ownedBy: lease) == sessionID else {
        throw supersededHandshakeFailure()
      }
      return try codec.roundTrip(response)
    } catch is CancellationError { throw CancellationError() } catch {
      throw codec.canonicalFailure(from: error)
    }
  }

  private static func controlsUnavailable() -> GatewayFailure {
    GatewayFailure(
      code: .transportUnavailable, message: "The resident control capability is unavailable.")
  }

  public func readArtifact(
    _ request: GatewayArtifactReadRequest, lease: GatewayTransportConnectionLease
  ) async throws -> GatewayArtifactReadResponse {
    try Task.checkCancellation()
    let sessionID = try requireSession(ownedBy: lease)
    do {
      let response = try await service.readArtifact(codec.roundTrip(request), sessionID: sessionID)
      try Task.checkCancellation()
      guard try requireSession(ownedBy: lease) == sessionID else {
        throw supersededHandshakeFailure()
      }
      let validated = try codec.roundTrip(response)
      try GatewayArtifactReadValidation.response(validated, request: request)
      return validated
    } catch is CancellationError { throw CancellationError() } catch {
      throw codec.canonicalFailure(from: error)
    }
  }

  public func eventRecords(
    after cursor: GatewayEventCursor,
    lease: GatewayTransportConnectionLease
  ) async throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error> {
    let sessionID = try requireSession(ownedBy: lease)

    let upstream: AsyncThrowingStream<GatewayEventEnvelope, any Error>
    do {
      let wireCursor = try codec.roundTrip(cursor)
      upstream = try await service.eventRecords(after: wireCursor, sessionID: sessionID)
    } catch {
      throw codec.canonicalFailure(from: error)
    }

    let pair = GatewayBufferedStream<GatewayEventEnvelope>.makeStream(
      bufferCapacity: configuration.subscriberBufferCapacity,
      maximumBufferedBytes: configuration.maximumBufferedWireBytesPerSubscriber)
    let stream = pair.stream
    let continuation = pair.continuation
    let codec = self.codec
    let task = Task {
      do {
        for try await envelope in upstream {
          let wire = try codec.encode(envelope)
          let wireEnvelope = try codec.decode(GatewayEventEnvelope.self, from: wire)
          switch continuation.yield(wireEnvelope, wireBytes: wire.count) {
          case .enqueued:
            continue
          case .dropped, .terminated:
            continuation.finish(
              throwing: GatewayFailure(
                code: .consumerTooSlow,
                message: "The transport consumer fell behind its bounded event buffer.",
                isRetryable: true
              )
            )
            return
          @unknown default:
            continuation.finish(
              throwing: GatewayFailure(
                code: .consumerTooSlow,
                message: "The transport could not enqueue an event record.",
                isRetryable: true
              )
            )
            return
          }
        }
        continuation.finish()
      } catch {
        continuation.finish(throwing: codec.canonicalFailure(from: error))
      }
    }

    continuation.onTermination = { @Sendable _ in
      task.cancel()
    }
    return stream
  }

  public func disconnect(lease: GatewayTransportConnectionLease) async {
    if latestHandshakeLease == lease {
      latestHandshakeAttemptID = nil
      latestHandshakeLease = nil
    }
    guard connectedLease == lease, let sessionID else {
      return
    }
    connectedLease = nil
    self.sessionID = nil
    await service.disconnect(sessionID: sessionID)
  }

  private func requireSession(
    ownedBy lease: GatewayTransportConnectionLease
  ) throws -> GatewaySessionID {
    guard connectedLease == lease, let sessionID else {
      throw GatewayFailure(
        code: .notConnected,
        message: "The in-process gateway transport lease is not connected.",
        isRetryable: true
      )
    }
    return sessionID
  }

  private func supersededHandshakeFailure() -> GatewayFailure {
    GatewayFailure(
      code: .disconnected,
      message: "The handshake was superseded by a newer connection attempt.",
      isRetryable: true
    )
  }
}
