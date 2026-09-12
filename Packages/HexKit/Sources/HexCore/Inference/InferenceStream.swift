import Synchronization

/// A single-consumer inference session with a structured cancellation lifetime.
///
/// `consume(_:)` owns the underlying event sequence for the duration of its closure. Every normal,
/// throwing, or cancelled closure exit cancels any remaining producer work and waits for that work
/// to terminate before returning. Dropping a never-consumed session requests cancellation, while
/// the provider remains responsible for retaining and joining its physical work asynchronously.
public final class InferenceStream: Sendable {
  private let cancellation: InferenceStreamCancellation
  private let events: AsyncThrowingStream<InferenceStreamEvent, any Error>
  private let termination: Task<Void, Never>
  private let state = Mutex(InferenceStreamState.idle)

  public init(
    events: AsyncThrowingStream<InferenceStreamEvent, any Error>,
    onCancellation: @escaping @Sendable () -> Void,
    waitForTermination: @escaping @Sendable () async -> Void
  ) {
    cancellation = InferenceStreamCancellation(action: onCancellation)
    termination = Task {
      await waitForTermination()
    }
    self.events = events
  }

  deinit {
    cancellation.cancel()
  }

  public func consume<Result: Sendable>(
    _ body:
      @Sendable (
        InferenceStreamCursor
      ) async throws -> Result
  ) async throws -> Result {
    let cursor = InferenceStreamCursor(events: events)
    try claimConsumption(cursor: cursor)
    let cancellation = cancellation
    let cursorControl = cursor.control
    let termination = termination

    return try await withTaskCancellationHandler {
      let result: Result
      do {
        result = try await body(cursor)
      } catch {
        cursor.close()
        cancellation.cancel()
        await termination.value
        let externallyCancelled = finishConsumption(cursor: cursor)
        if Task.isCancelled {
          throw CancellationError()
        }
        if externallyCancelled {
          throw InferenceStreamError.cancelled
        }
        throw error
      }
      cursor.close()
      cancellation.cancel()
      await termination.value
      let externallyCancelled = finishConsumption(cursor: cursor)
      try Task.checkCancellation()
      if externallyCancelled {
        throw InferenceStreamError.cancelled
      }
      return result
    } onCancel: {
      cancellation.cancel()
      cursorControl.close()
    }
  }

  public func cancelAndWait() async {
    let control = state.withLock { state -> InferenceStreamCursorControl? in
      switch state {
      case .idle:
        state = .cancelled
        return nil
      case .consuming(let control):
        state = .cancelled
        return control
      case .cancelled, .finished:
        return nil
      }
    }
    cancellation.cancel()
    control?.close()
    await termination.value
  }

  private func claimConsumption(cursor: InferenceStreamCursor) throws {
    let error = state.withLock { state -> InferenceStreamError? in
      switch state {
      case .idle:
        state = .consuming(cursor.control)
        return nil
      case .cancelled:
        return .cancelled
      case .consuming, .finished:
        return .alreadyConsumed
      }
    }
    if let error {
      throw error
    }
  }

  private func finishConsumption(cursor: InferenceStreamCursor) -> Bool {
    state.withLock { state in
      switch state {
      case .consuming(let activeControl) where activeControl === cursor.control:
        state = .finished
        return false
      case .cancelled:
        return true
      case .idle, .consuming, .finished:
        return false
      }
    }
  }

}
