import Foundation

struct LlamaCppChatCompletionChunk: Decodable, Sendable {
  let id: String?
  let choices: [Choice]
  let usage: Usage?

  struct Choice: Decodable, Sendable {
    let delta: Delta
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
      case delta
      case finishReason = "finish_reason"
    }
  }

  struct Delta: Decodable, Sendable {
    let content: String?
    let reasoningContent: String?
    let reasoning: String?
    let toolCalls: [ToolCallDelta]?

    enum CodingKeys: String, CodingKey {
      case content
      case reasoningContent = "reasoning_content"
      case reasoning
      case toolCalls = "tool_calls"
    }
  }

  struct ToolCallDelta: Decodable, Sendable {
    let index: Int?
    let id: String?
    let function: FunctionDelta?
  }

  struct FunctionDelta: Decodable, Sendable {
    let name: String?
    let arguments: String?
  }

  struct Usage: Decodable, Sendable {
    let promptTokens: Int
    let completionTokens: Int

    enum CodingKeys: String, CodingKey {
      case promptTokens = "prompt_tokens"
      case completionTokens = "completion_tokens"
    }
  }
}
