import HexCore

struct OpenAIAssistantMirror: Sendable {
  let text: String
  let calls: [ToolCall]
}
