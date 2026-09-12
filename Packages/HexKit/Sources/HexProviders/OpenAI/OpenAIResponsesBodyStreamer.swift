import Foundation

/// Delivers SSE lines as they arrive while keeping oversized lines and queued bytes bounded.
struct OpenAIResponsesBodyStreamer {
  static func start<Bytes: AsyncSequence & Sendable>(
    _ bytes: Bytes
  ) -> (body: AsyncThrowingStream<Data, any Error>, producer: Task<Void, Never>)
  where Bytes.Element == UInt8 {
    let (body, continuation) = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(4_096)
    )
    let producer = Task {
      do {
        var chunk = Data()
        chunk.reserveCapacity(8 * 1_024)
        for try await byte in bytes {
          try Task.checkCancellation()
          chunk.append(byte)
          // Flush line endings immediately. Waiting for 8 KiB can hold a whole short answer
          // until the server sends its terminal envelope. The SSE parser owns framing/UTF-8.
          if byte == 10 || byte == 13 || chunk.count == 8 * 1_024 {
            try yield(chunk, to: continuation)
            chunk.removeAll(keepingCapacity: true)
          }
        }
        try Task.checkCancellation()
        if !chunk.isEmpty {
          try yield(chunk, to: continuation)
        }
        continuation.finish()
      } catch {
        continuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
      }
    }
    return (body, producer)
  }

  private static func yield(
    _ data: Data,
    to continuation: AsyncThrowingStream<Data, any Error>.Continuation
  ) throws {
    switch continuation.yield(data) {
    case .enqueued:
      return
    case .dropped:
      throw URLError(.dataLengthExceedsMaximum)
    case .terminated:
      throw CancellationError()
    @unknown default:
      throw URLError(.unknown)
    }
  }
}
