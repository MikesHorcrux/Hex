import Foundation
import HexCore

/// A bounded loopback transport for local development and deterministic tests. Both endpoints remain
/// in one process. It does not launch `HexGateway`, survive app termination, provide XPC isolation, or
/// expand the app's sandbox, filesystem, terminal, privacy, or network privileges.
/// Its configuration bounds client-side encoding and forwarding; the service independently enforces
/// its own envelope, so a larger transport configuration never weakens service admission.
public actor InProcessHexGatewayTransport: HexGatewayTransport {
  private let service: HexGatewayService
  private let configuration: GatewayConfiguration
  private let codec: GatewayWireCodec
  private var sessionID: GatewaySessionID?
  private var connectedLease: GatewayTransportConnectionLease?
  private var latestHandshakeAttemptID: UUID?
  private var latestHandshakeLease: GatewayTransportConnectionLease?

  public init(
    service: HexGatewayService,
    configuration: GatewayConfiguration = .standard
  ) {
    self.service = service
    self.configuration = configuration
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

    let pair = AsyncThrowingStream<GatewayEventEnvelope, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(configuration.subscriberBufferCapacity)
    )
    let stream = pair.stream
    let continuation = pair.continuation
    let codec = self.codec
    let task = Task {
      do {
        for try await envelope in upstream {
          let wireEnvelope = try codec.roundTrip(envelope)
          switch continuation.yield(wireEnvelope) {
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
