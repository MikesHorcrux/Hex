import Synchronization

final class InferenceStreamCancellation: Sendable {
  private let state = Mutex(false)
  private let action: @Sendable () -> Void

  init(action: @escaping @Sendable () -> Void) {
    self.action = action
  }

  func cancel() {
    let shouldCancel = state.withLock { isCancelled in
      guard !isCancelled else {
        return false
      }
      isCancelled = true
      return true
    }
    if shouldCancel {
      action()
    }
  }
}
