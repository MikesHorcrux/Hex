import Synchronization

/// Makes task cancellation synchronously visible to actor-isolated admission without moving mutable
/// gateway state outside `HexGatewayClient`.
final class GatewayClientEventStreamCancellationState: Sendable {
  private let storage = Mutex(
    (
      isCancelled: false,
      cancellationHandler: Optional<@Sendable () -> Void>.none
    )
  )

  var isCancelled: Bool {
    storage.withLock { state in
      state.isCancelled
    }
  }

  func cancel() {
    let cancellationHandler = storage.withLock { state in
      state.isCancelled = true
      let cancellationHandler = state.cancellationHandler
      state.cancellationHandler = nil
      return cancellationHandler
    }
    cancellationHandler?()
  }

  func installCancellationHandler(_ cancellationHandler: @escaping @Sendable () -> Void) {
    let shouldCancel = storage.withLock { state in
      guard !state.isCancelled else {
        return true
      }
      state.cancellationHandler = cancellationHandler
      return false
    }
    if shouldCancel {
      cancellationHandler()
    }
  }

  func removeCancellationHandler() {
    storage.withLock { state in
      state.cancellationHandler = nil
    }
  }
}
