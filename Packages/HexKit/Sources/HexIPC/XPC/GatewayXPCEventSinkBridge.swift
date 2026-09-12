@preconcurrency import Foundation

/// Owns one in-flight XPC payload until the receiver acknowledges bounded admission. A missing
/// reply, failed admission, or cancellation seals this bridge; late replies cannot admit more work.
public actor GatewayXPCEventSinkBridge {
  private let sink: any HexGatewayXPCEventSinkProtocol
  private let acknowledgementTimeout: Duration
  private var pending: GatewayXPCEventSinkBridgePendingAcknowledgement?
  private var isSealed = false

  public init(
    sink: sending any HexGatewayXPCEventSinkProtocol,
    acknowledgementTimeout: Duration = .seconds(10)
  ) {
    self.sink = sink
    self.acknowledgementTimeout = acknowledgementTimeout
  }

  public func receiveEvent(_ envelope: Data) async throws {
    try Task.checkCancellation()
    guard !isSealed else { throw unavailableFailure() }
    guard pending == nil else {
      throw GatewayFailure(
        code: .capacityExceeded,
        message: "The XPC event receiver already has an unacknowledged payload.")
    }
    guard acknowledgementTimeout > .zero else {
      isSealed = true
      throw unavailableFailure()
    }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        guard !Task.isCancelled else {
          isSealed = true
          continuation.resume(throwing: CancellationError())
          return
        }
        let timeout = acknowledgementTimeout
        let timer = Task { [weak self] in
          do { try await Task.sleep(for: timeout) } catch { return }
          await self?.expireAcknowledgement(id)
        }
        pending = GatewayXPCEventSinkBridgePendingAcknowledgement(
          id: id, continuation: continuation, timer: timer)
        sink.receiveEvent(envelope) { [weak self] accepted in
          Task { await self?.acknowledge(id, accepted: accepted) }
        }
      }
    } onCancel: {
      Task { await self.cancelAcknowledgement(id) }
    }
    try Task.checkCancellation()
  }

  public func finish(_ response: Data) {
    isSealed = true
    if let id = pending?.id { failAcknowledgement(id, error: unavailableFailure()) }
    sink.finish(response)
  }

  private func acknowledge(_ id: UUID, accepted: Bool) {
    guard pending?.id == id else { return }
    guard accepted else {
      failAcknowledgement(
        id,
        error: GatewayFailure(
          code: .consumerTooSlow,
          message: "The XPC event receiver could not admit the next bounded payload.",
          isRetryable: true))
      return
    }
    let completed = pending
    pending = nil
    completed?.timer.cancel()
    completed?.continuation.resume()
  }

  private func expireAcknowledgement(_ id: UUID) {
    failAcknowledgement(id, error: unavailableFailure())
  }

  private func cancelAcknowledgement(_ id: UUID) {
    failAcknowledgement(id, error: CancellationError())
  }

  private func failAcknowledgement(_ id: UUID, error: any Error) {
    guard let failed = pending, failed.id == id else { return }
    pending = nil
    isSealed = true
    failed.timer.cancel()
    failed.continuation.resume(throwing: error)
  }

  private func unavailableFailure() -> GatewayFailure {
    GatewayFailure(
      code: .transportUnavailable,
      message:
        "The XPC event receiver did not acknowledge delivery. Reconnect and recover saved run history; no run was repeated.",
      isRetryable: true)
  }
}
