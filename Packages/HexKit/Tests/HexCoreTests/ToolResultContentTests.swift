import Foundation
import HexCore
import Testing

@Suite("Tool-result content")
struct ToolResultContentTests {
  @Test
  func roundTripsTextAndImageContent() throws {
    let imageURL = try #require(URL(string: "data:image/jpeg;base64,YQ=="))
    let result = ToolResult(
      toolCallID: ToolCallID(rawValue: "call-screen-1"),
      status: .success,
      output: .object(["window": .string("Xcode")]),
      content: [
        .text("The frontmost window was captured."),
        .image(
          ImageContent(
            sourceURL: imageURL,
            mediaType: "image/jpeg"
          )
        ),
      ]
    )

    let encoded = try JSONEncoder().encode(result)
    let decoded = try JSONDecoder().decode(ToolResult.self, from: encoded)

    #expect(decoded == result)
  }

  @Test
  func decodesLegacyResultWithoutContent() throws {
    let data = Data(
      #"{"toolCallID":"call-legacy-1","status":"success","output":"done"}"#.utf8
    )

    let result = try JSONDecoder().decode(ToolResult.self, from: data)

    #expect(result.toolCallID == ToolCallID(rawValue: "call-legacy-1"))
    #expect(result.output == .string("done"))
    #expect(result.content.isEmpty)
  }

  @Test
  func rejectsUnknownContentKind() throws {
    let data = Data(#"{"type":"audio","text":"unexpected"}"#.utf8)

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ToolResultContent.self, from: data)
    }
  }
}
