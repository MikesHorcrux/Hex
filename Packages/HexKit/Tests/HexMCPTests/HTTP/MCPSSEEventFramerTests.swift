import Foundation
import Testing

@testable import HexMCP

@Suite("MCP SSE event framing")
struct MCPSSEEventFramerTests {
  @Test(
    "Frames separate events across every SSE line-ending form", arguments: ["\n", "\r", "\r\n"])
  func framesEvents(lineEnding: String) throws {
    let source =
      "data: {\"first\":1}\(lineEnding)\(lineEnding)"
      + ": keepalive\(lineEnding)\(lineEnding)"
      + "data: {\"second\":2}\(lineEnding)\(lineEnding)"
    var framer = MCPSSEEventFramer()
    let frames = Array(source.utf8).compactMap { framer.append($0) }
    #expect(frames.count == 3)
    let remainder = framer.finish()
    #expect(remainder == nil)
    let counts = try frames.map {
      try MCPSSEMessageDecoder.decode($0, maximumEvents: 1, maximumMessageBytes: 1_024).count
    }
    #expect(counts == [1, 0, 1])
  }

  @Test("Retains an incomplete final event until end of input")
  func retainsFinalEvent() throws {
    var framer = MCPSSEEventFramer()
    let completed = Array("data: {\"last\":1}".utf8).compactMap { framer.append($0) }
    #expect(completed.isEmpty)
    let finalFrame = framer.finish()
    let final = try #require(finalFrame)
    #expect(
      try MCPSSEMessageDecoder.decode(final, maximumEvents: 1, maximumMessageBytes: 1_024).count
        == 1)
    let remainder = framer.finish()
    #expect(remainder == nil)
  }
}
