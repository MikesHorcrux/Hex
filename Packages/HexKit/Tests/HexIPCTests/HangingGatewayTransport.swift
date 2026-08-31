import Foundation
import HexCore
import HexIPC

actor HangingGatewayTransport: HexGatewayTransport {
  private var holdsStreamAcquisition: Bool
  private var connectedLease: GatewayTransportConnectionLease?
  private var continuations:
    [UUID: AsyncThrowingStream<GatewayEventEnvelope, any Error>.Continuation] = [:]
  private var pendingContinuations:
    [UUID: CheckedContinuation<
      AsyncThrowingStream<GatewayEventEnvelope, any Error>,
      any Error
    >] = [:]
  private var pendingOrder: [UUID] = []
  private var pendingCountWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
  private var activeCountWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
  private(set) var maximumPendingStreamCount = 0

  init(holdsStreamAcquisition: Bool = false) {
    self.holdsStreamAcquisition = holdsStreamAcquisition
  }

  var activeStreamCount: Int {
    continuations.count
  }

  var pendingStreamCount: Int {
    pendingContinuations.count
  }

  func handshake(
    _ request: GatewayHandshakeRequest,
    lease: GatewayTransportConnectionLease
  ) -> GatewayHandshakeResponse {
    connectedLease = lease
    return GatewayHandshakeResponse(
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(227)),
      gatewayInstanceID: GatewayInstanceID(rawValue: GatewayTestValues.uuid(228)),
      selectedVersion: .current,
      activeRun: nil
    )
  }

  func startRun(
    _ request: GatewayStartRunRequest,
    lease: GatewayTransportConnectionLease
  ) throws -> GatewayStartRunResponse {
    try requireConnection(lease)
    return GatewayStartRunResponse(
      runID: request.runID,
      disposition: .started(invocationID: GatewayTestValues.invocationID(227))
    )
  }

  func cancelRun(
    _ request: GatewayCancelRunRequest,
    lease: GatewayTransportConnectionLease
  ) throws -> GatewayCancelRunResponse {
    try requireConnection(lease)
    return GatewayCancelRunResponse(
      runID: request.runID,
      invocationID: request.invocationID,
      disposition: .requested
    )
  }

  func eventRecords(
    after cursor: GatewayEventCursor,
    lease: GatewayTransportConnectionLease
  ) async throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error> {
    try requireConnection(lease)
    if holdsStreamAcquisition {
      let requestID = UUID()
      return try await withCheckedThrowingContinuation { continuation in
        pendingContinuations[requestID] = continuation
        pendingOrder.append(requestID)
        maximumPendingStreamCount = max(maximumPendingStreamCount, pendingContinuations.count)
        resumePendingCountWaiters()
      }
    }
    return installStream()
  }

  func resolvePendingStreams() {
    let requestIDs = pendingOrder
    pendingOrder.removeAll(keepingCapacity: true)
    for requestID in requestIDs {
      pendingContinuations.removeValue(forKey: requestID)?.resume(
        returning: installStream()
      )
    }
    resumePendingCountWaiters()
  }

  func allowPendingStreamAcquisitionsToResolve() {
    holdsStreamAcquisition = false
    resolvePendingStreams()
  }

  func failPendingStreamAcquisitionsAndAllowFutureOnes(message: String) {
    holdsStreamAcquisition = false
    let requestIDs = pendingOrder
    pendingOrder.removeAll(keepingCapacity: true)
    for requestID in requestIDs {
      pendingContinuations.removeValue(forKey: requestID)?.resume(
        throwing: GatewayFailure(
          code: .transportUnavailable,
          message: message,
          isRetryable: true
        )
      )
    }
    resumePendingCountWaiters()
  }

  func waitForPendingStreamCount(_ expectedCount: Int) async {
    guard pendingContinuations.count != expectedCount else {
      return
    }
    await withCheckedContinuation { continuation in
      pendingCountWaiters[expectedCount, default: []].append(continuation)
    }
  }

  func waitForActiveStreamCount(_ expectedCount: Int) async {
    guard continuations.count != expectedCount else {
      return
    }
    await withCheckedContinuation { continuation in
      activeCountWaiters[expectedCount, default: []].append(continuation)
    }
  }

  private func installStream() -> AsyncThrowingStream<GatewayEventEnvelope, any Error> {
    let streamID = UUID()
    let pair = AsyncThrowingStream<GatewayEventEnvelope, any Error>.makeStream()
    continuations[streamID] = pair.continuation
    resumeActiveCountWaiters()
    pair.continuation.onTermination = { @Sendable _ in
      Task {
        await self.removeStream(streamID)
      }
    }
    return pair.stream
  }

  func disconnect(lease: GatewayTransportConnectionLease) {
    guard connectedLease == lease else {
      return
    }
    connectedLease = nil
    let pending = Array(pendingContinuations.values)
    pendingContinuations.removeAll()
    pendingOrder.removeAll(keepingCapacity: true)
    resumePendingCountWaiters()
    let activeContinuations = Array(continuations.values)
    continuations.removeAll()
    resumeActiveCountWaiters()
    for continuation in activeContinuations {
      continuation.finish()
    }
    for continuation in pending {
      continuation.resume(
        throwing: GatewayFailure(
          code: .disconnected,
          message: "The hanging transport disconnected while acquiring a stream."
        )
      )
    }
  }

  private func removeStream(_ streamID: UUID) {
    continuations.removeValue(forKey: streamID)
    resumeActiveCountWaiters()
  }

  private func resumePendingCountWaiters() {
    let waiters = pendingCountWaiters.removeValue(forKey: pendingContinuations.count) ?? []
    for waiter in waiters {
      waiter.resume()
    }
  }

  private func resumeActiveCountWaiters() {
    let waiters = activeCountWaiters.removeValue(forKey: continuations.count) ?? []
    for waiter in waiters {
      waiter.resume()
    }
  }

  private func requireConnection(_ lease: GatewayTransportConnectionLease) throws {
    guard connectedLease == lease else {
      throw GatewayFailure(
        code: .notConnected,
        message: "The hanging transport is disconnected."
      )
    }
  }
}
