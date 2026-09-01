import Foundation

/// Physical, message-atomic byte channel used by a Codex app-server connection.
///
/// `open` must preserve byte order, emit chunks no larger than `maximumReadBytes`, and bound any
/// producer-side buffering. If preserving all bytes would exceed that bound, it must fail the
/// stream and close the physical transport instead of dropping bytes or buffering without limit.
/// `write` must serialize each supplied JSONL frame without interleaving it with another write.
/// `close` must be idempotent and return only after the physical channel no longer accepts I/O.
public protocol CodexAppServerChannel: Sendable {
  func open(maximumReadBytes: Int) async throws -> AsyncThrowingStream<Data, any Error>

  func write(_ frame: Data) async throws

  func close() async
}
