import Synchronization

/// Serializes resident-listener activation with task cancellation. The cancellation handler can run
/// concurrently with the main-actor operation, so the lock keeps cancellation from invalidating a
/// listener between the operation's final check and its synchronous activation call.
final class HexGatewayResidentCancellationGate: Sendable {
  private let storage = Mutex(
    (
      isCancelled: false,
      isActivated: false,
      cancellationHandler: Optional<@Sendable () -> Void>.none
    )
  )

  func activate(_ operation: () -> Void) -> Bool {
    storage.withLock { state in
      guard !state.isCancelled else {
        return false
      }
      operation()
      state.isActivated = true
      return true
    }
  }

  func installCancellationHandler(_ handler: @escaping @Sendable () -> Void) {
    let shouldInvoke = storage.withLock { state in
      guard !state.isCancelled else {
        return true
      }
      state.cancellationHandler = handler
      return false
    }
    if shouldInvoke {
      handler()
    }
  }

  func cancel() {
    let handler = storage.withLock { state in
      state.isCancelled = true
      guard state.isActivated else {
        return Optional<@Sendable () -> Void>.none
      }
      let handler = state.cancellationHandler
      state.cancellationHandler = nil
      return handler
    }
    handler?()
  }

  func removeCancellationHandler() {
    storage.withLock { state in
      state.cancellationHandler = nil
    }
  }
}
