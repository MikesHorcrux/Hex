import Foundation
import HexCore
import Testing

@Suite("Messages")
struct MessageTests {
  @Test
  func preservesEveryRoleIncludingDeveloper() throws {
    for role in MessageRole.allCases {
      let message = Message(role: role, content: [.text(role.rawValue)])
      #expect(try roundTrip(message) == message)
    }

    #expect(MessageRole.developer != .system)
  }

  @Test
  func roundTripsEveryContentCase() throws {
    let call = ToolCall(
      id: ToolCallID(rawValue: "call-1"),
      name: "read_file",
      arguments: ["path": .string("/tmp/example")]
    )
    let result = ToolResult(
      toolCallID: call.id,
      status: .success,
      output: .string("contents")
    )
    let imageURL = try #require(URL(string: "https://example.com/image.png"))
    let image = ImageContent(
      sourceURL: imageURL,
      mediaType: "image/png"
    )
    let message = Message(
      role: .assistant,
      content: [
        .text("hello"),
        .image(image),
        .toolCall(call),
        .toolResult(result),
      ]
    )

    #expect(try roundTrip(message) == message)
  }

  private func roundTrip(_ value: Message) throws -> Message {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Message.self, from: data)
  }
}
