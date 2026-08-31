/// The single scoped cursor handed to an `InferenceStream` consumer.
///
/// A cursor cannot create additional iterators. It closes when its consumption scope ends, so a
/// retained cursor cannot continue reading buffered events after producer teardown.
public final class InferenceStreamCursor {
  private var iterator: AsyncThrowingStream<InferenceStreamEvent, any Error>.Iterator
  let control = InferenceStreamCursorControl()

  init(
    events: AsyncThrowingStream<InferenceStreamEvent, any Error>
  ) {
    iterator = events.makeAsyncIterator()
  }

  public func next() async throws -> InferenceStreamEvent? {
    try control.beginRead()
    defer {
      control.endRead()
    }
    do {
      let event = try await iterator.next()
      try control.requireOpen()
      return event
    } catch {
      try control.requireOpen()
      throw error
    }
  }

  func close() {
    control.close()
  }
}
