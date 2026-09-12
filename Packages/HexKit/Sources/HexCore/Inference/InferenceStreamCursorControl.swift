import Synchronization

final class InferenceStreamCursorControl: Sendable {
  private let state = Mutex(InferenceStreamCursorControlState())

  func beginRead() throws {
    try state.withLock { state in
      guard state.isOpen else {
        throw InferenceStreamError.closed
      }
      guard !state.isReading else {
        throw InferenceStreamError.concurrentRead
      }
      state.isReading = true
    }
  }

  func endRead() {
    state.withLock { state in
      state.isReading = false
    }
  }

  func requireOpen() throws {
    try state.withLock { state in
      guard state.isOpen else {
        throw InferenceStreamError.closed
      }
    }
  }

  func close() {
    state.withLock { state in
      state.isOpen = false
    }
  }

}
