/// A bounded stream charged for actual wire bytes, not the maximum possible size of every token.
/// The unfolding adapter only pulls: it creates no forwarding task or second event queue.
enum GatewayBufferedStream<Element: Sendable> {
  static func makeStream(bufferCapacity: Int, maximumBufferedBytes: Int) -> (
    stream: AsyncThrowingStream<Element, any Error>,
    continuation: GatewayBufferedStreamContinuation<Element>
  ) {
    let pair = AsyncThrowingStream<GatewayBufferedStreamEntry<Element>, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(bufferCapacity))
    let continuation = GatewayBufferedStreamContinuation<Element>(
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
