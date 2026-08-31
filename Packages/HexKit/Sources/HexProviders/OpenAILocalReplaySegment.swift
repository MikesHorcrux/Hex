import HexCore

struct OpenAILocalReplaySegment: Sendable {
  let afterMessageCount: Int
  let outputItems: [JSONValue]
  let encodedByteCount: Int
}
