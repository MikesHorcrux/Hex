import Synchronization

/// A bounded stream charged for actual wire bytes, not the maximum possible size of every token.
/// The unfolding adapter only pulls: it creates no forwarding task or second event queue.
enum GatewayBufferedStream<Element: Sendable> {
  fileprivate struct Entry: Sendable {
    let value: Element
    let wireBytes: Int
  }

  final class Continuation: Sendable {
    private typealias Termination = AsyncThrowingStream<Element, any Error>.Continuation.Termination
    private struct State {
      var bufferedBytes = 0
      var termination: Termination?
      var onTermination: (@Sendable (Termination) -> Void)?
    }
    private enum Admission { case accepted, full, terminated }

    private let base: AsyncThrowingStream<Entry, any Error>.Continuation
    private let state = Mutex(State())
    private let maximumBufferedBytes: Int

    fileprivate init(
      base: AsyncThrowingStream<Entry, any Error>.Continuation, maximumBufferedBytes: Int
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
      let admitted = state.withLock { state -> Admission in
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
      switch base.yield(Entry(value: value, wireBytes: wireBytes)) {
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

    fileprivate func release(_ wireBytes: Int) {
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

  static func makeStream(bufferCapacity: Int, maximumBufferedBytes: Int) -> (
    stream: AsyncThrowingStream<Element, any Error>, continuation: Continuation
  ) {
    let pair = AsyncThrowingStream<Entry, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(bufferCapacity))
    let continuation = Continuation(
      base: pair.continuation, maximumBufferedBytes: maximumBufferedBytes)
    let upstream = pair.stream
    let stream = AsyncThrowingStream<Element, any Error>(unfolding: {
      // AsyncThrowingStream iterators share the stream's storage. A fresh iterator per serial pull
      // avoids sending a mutable iterator across isolation domains; it does not replay events.
      var iterator = upstream.makeAsyncIterator()
      guard let entry = try await iterator.next() else { return nil }
      continuation.release(entry.wireBytes)
      return entry.value
    })
    return (stream, continuation)
  }
}
