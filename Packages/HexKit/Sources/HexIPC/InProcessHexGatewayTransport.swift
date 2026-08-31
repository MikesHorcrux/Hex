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
  private var latestHandshakeAttemptID: UUID?

  public init(
    service: HexGatewayService,
    configuration: GatewayConfiguration = .standard
  ) {
    self.service = service
    self.configuration = configuration
    codec = GatewayWireCodec(configuration: configuration)
  }

  public func handshake(
    _ request: GatewayHandshakeRequest
  ) async throws -> GatewayHandshakeResponse {
    let attemptID = UUID()
    latestHandshakeAttemptID = attemptID
    if let sessionID {
      self.sessionID = nil
      await service.disconnect(sessionID: sessionID)
    }

    do {
      guard latestHandshakeAttemptID == attemptID else {
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

      guard latestHandshakeAttemptID == attemptID else {
        await service.disconnect(sessionID: response.sessionID)
        throw supersededHandshakeFailure()
      }
      sessionID = wireResponse.sessionID
      latestHandshakeAttemptID = nil
      return wireResponse
    } catch {
      if latestHandshakeAttemptID == attemptID {
        latestHandshakeAttemptID = nil
      }
      throw codec.canonicalFailure(from: error)
    }
  }

  public func startRun(
    _ request: GatewayStartRunRequest
  ) async throws -> GatewayStartRunResponse {
    guard let sessionID else {
      throw GatewayFailure(
        code: .notConnected,
        message: "The in-process gateway transport has not completed a handshake.",
        isRetryable: true
      )
    }

    do {
      let wireRequest = try codec.roundTrip(request)
      let response = try await service.startRun(wireRequest, sessionID: sessionID)
      return try codec.roundTrip(response)
    } catch {
      throw codec.canonicalFailure(from: error)
    }
  }

  public func cancelRun(
    _ request: GatewayCancelRunRequest
  ) async throws -> GatewayCancelRunResponse {
    guard let sessionID else {
      throw GatewayFailure(
        code: .notConnected,
        message: "The in-process gateway transport has not completed a handshake.",
        isRetryable: true
      )
    }

    do {
      let wireRequest = try codec.roundTrip(request)
      let response = try await service.cancelRun(wireRequest, sessionID: sessionID)
      return try codec.roundTrip(response)
    } catch {
      throw codec.canonicalFailure(from: error)
    }
  }

  public func eventRecords(
    after cursor: GatewayEventCursor
  ) async throws -> AsyncThrowingStream<AgentEventRecord, any Error> {
    guard let sessionID else {
      throw GatewayFailure(
        code: .notConnected,
        message: "The in-process gateway transport has not completed a handshake.",
        isRetryable: true
      )
    }

    let upstream: AsyncThrowingStream<AgentEventRecord, any Error>
    do {
      let wireCursor = try codec.roundTrip(cursor)
      upstream = try await service.eventRecords(after: wireCursor, sessionID: sessionID)
    } catch {
      throw codec.canonicalFailure(from: error)
    }

    let pair = AsyncThrowingStream<AgentEventRecord, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(configuration.subscriberBufferCapacity)
    )
    let stream = pair.stream
    let continuation = pair.continuation
    let codec = self.codec
    let task = Task {
      do {
        for try await record in upstream {
          let wireRecord = try codec.roundTrip(record)
          switch continuation.yield(wireRecord) {
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

  public func disconnect() async {
    latestHandshakeAttemptID = nil
    guard let sessionID else {
      return
    }
    self.sessionID = nil
    await service.disconnect(sessionID: sessionID)
  }

  private func supersededHandshakeFailure() -> GatewayFailure {
    GatewayFailure(
      code: .disconnected,
      message: "The handshake was superseded by a newer connection attempt.",
      isRetryable: true
    )
  }
}
