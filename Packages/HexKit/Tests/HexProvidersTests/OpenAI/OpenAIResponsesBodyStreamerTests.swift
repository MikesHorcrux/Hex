import Foundation
import Testing

@testable import HexProviders

@Suite("OpenAI response byte delivery")
struct OpenAIResponsesBodyStreamerTests {
  @Test(arguments: ["\n", "\r", "\r\n"])
  func smallEventArrivesWhileConnectionRemainsOpen(lineEnding: String) async throws {
    let (bytes, continuation) = AsyncThrowingStream.makeStream(of: UInt8.self)
    let (body, producer) = OpenAIResponsesBodyStreamer.start(bytes)
    defer {
      continuation.finish()
      producer.cancel()
    }
    let line = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}"
    for byte in (line + lineEnding + lineEnding).utf8 {
      continuation.yield(byte)
    }
    // The source is deliberately not finished: the first chunk must not wait for EOF or 8 KiB.
    let received = try await withThrowingTaskGroup(of: Data?.self) { group in
      group.addTask {
        var iterator = body.makeAsyncIterator()
        return try await iterator.next()
      }
      group.addTask {
        try await Task.sleep(for: .seconds(2))
        throw URLError(.timedOut)
      }
      defer { group.cancelAll() }
      return try await group.next() ?? nil
    }
    var expected = Data(line.utf8)
    expected.append(contentsOf: lineEnding.utf8.prefix(1))
    #expect(received == expected)
    continuation.finish()
    await producer.value
  }

  @Test
  func preservesAllBytesAcrossChunkAndMultibyteBoundaries() async throws {
    let expected = Data((String(repeating: "é", count: 9_000) + "\r\n\r\n" + "tail").utf8)
    let bytes = AsyncThrowingStream<UInt8, any Error> { continuation in
      for byte in expected { continuation.yield(byte) }
      continuation.finish()
    }
    let (body, producer) = OpenAIResponsesBodyStreamer.start(bytes)
    var received = Data()
    for try await chunk in body {
      #expect(chunk.count <= 8 * 1_024)
      received.append(chunk)
    }
    await producer.value
    #expect(received == expected)
  }

  @Test
  func cancellationStopsProducerWhileSourceRemainsOpen() async throws {
    let (bytes, continuation) = AsyncThrowingStream.makeStream(of: UInt8.self)
    let (body, producer) = OpenAIResponsesBodyStreamer.start(bytes)
    defer { continuation.finish() }
    continuation.yield(UInt8(ascii: "x"))
    producer.cancel()

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await producer.value }
      group.addTask {
        try await Task.sleep(for: .seconds(2))
        throw URLError(.timedOut)
      }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
    do {
      for try await _ in body {}
      Issue.record("Expected cancellation while the source remains open.")
    } catch is CancellationError {
      // The source never finished normally; cancellation terminated the producer and body.
    }
  }

  @Test
  func queueOverflowFailsExplicitlyInsteadOfDroppingResponseBytes() async throws {
    let bytes = AsyncThrowingStream<UInt8, any Error> { continuation in
      for _ in 0..<5_000 { continuation.yield(10) }
      continuation.finish()
    }
    let (body, producer) = OpenAIResponsesBodyStreamer.start(bytes)
    await producer.value
    do {
      for try await _ in body {}
      Issue.record("Expected bounded queue overflow to fail.")
    } catch let error as URLError {
      #expect(error.code == .dataLengthExceedsMaximum)
    }
  }
}
