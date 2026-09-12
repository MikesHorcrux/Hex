import Synchronization

final class GatewayBufferedStreamContinuation<Element: Sendable>: Sendable {
  private typealias Termination = AsyncThrowingStream<Element, any Error>.Continuation.Termination

  private let base: AsyncThrowingStream<GatewayBufferedStreamEntry<Element>, any Error>.Continuation
  private let state = Mutex(GatewayBufferedStreamState<Element>())
  private let maximumBufferedBytes: Int

  init(
    base: AsyncThrowingStream<GatewayBufferedStreamEntry<Element>, any Error>.Continuation,
    maximumBufferedBytes: Int
  ) {
    self.base = base
    self.maximumBufferedBytes = maximumBufferedBytes
    base.onTermination = { [weak self] termination in
      switch termination {
      case .cancelled: self?.terminate(.cancelled)
      case .finished(let error): self?.terminate(.finished(error))
      @unknown default: self?.terminate(.cancelled)
      }
    }
  }

  var onTermination:
    (@Sendable (AsyncThrowingStream<Element, any Error>.Continuation.Termination) -> Void)?
  {
    get { state.withLock { $0.onTermination } }
    set {
      let terminal = state.withLock { state -> Termination? in
        if let terminal = state.termination { return terminal }
        state.onTermination = newValue
        return nil
      }
      if let terminal { newValue?(terminal) }
    }
  }

  func yield(_ value: Element, wireBytes: Int)
    -> AsyncThrowingStream<Element, any Error>.Continuation.YieldResult
  {
    let admitted = state.withLock { state -> GatewayBufferedStreamAdmission in
      guard state.termination == nil else { return .terminated }
      guard wireBytes > 0, wireBytes <= maximumBufferedBytes - state.bufferedBytes else {
        return .full
      }
      state.bufferedBytes += wireBytes
      return .accepted
    }
    switch admitted {
    case .terminated: return .terminated
    case .full: return .dropped(value)
    case .accepted: break
    }
    switch base.yield(GatewayBufferedStreamEntry(value: value, wireBytes: wireBytes)) {
    case .enqueued(let remaining): return .enqueued(remaining: remaining)
    case .dropped:
      release(wireBytes)
      return .dropped(value)
    case .terminated:
      release(wireBytes)
      return .terminated
    @unknown default:
      release(wireBytes)
      return .terminated
    }
  }

  func finish(throwing error: (any Error)? = nil) {
    base.finish(throwing: error)
  }

  func release(_ wireBytes: Int) {
    state.withLock { $0.bufferedBytes -= wireBytes }
  }

  private func terminate(_ termination: Termination) {
    let handler = state.withLock { state -> (@Sendable (Termination) -> Void)? in
      guard state.termination == nil else { return nil }
      state.termination = termination
      let handler = state.onTermination
      state.onTermination = nil
      return handler
    }
    // Release captured producers/clients at the terminal boundary and never invoke user code
    // while holding the accounting lock. Accepted entries remain available for normal draining.
    handler?(termination)
  }
}
