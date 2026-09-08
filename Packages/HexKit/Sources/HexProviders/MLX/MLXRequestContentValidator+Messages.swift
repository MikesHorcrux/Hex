import HexCore

extension MLXRequestContentValidator {
  static func validateTextMessage(
    _ message: Message,
    remainingBytes: inout Int,
    remainingNodes: inout Int
  ) -> Bool {
    guard !message.content.isEmpty else {
      return false
    }
    var containsText = false
    for content in message.content {
      guard
        consumeNode(remainingNodes: &remainingNodes),
        case .text(let text) = content,
        !text.contains("\0"),
        consumeString(text, remainingBytes: &remainingBytes)
      else {
        return false
      }
      containsText = containsText || !text.isEmpty
    }
    return containsText
  }

  static func validateAssistantMessage(
    _ message: Message,
    unresolvedToolCalls: inout Set<ToolCallID>,
    seenToolCalls: inout Set<ToolCallID>,
    remainingBytes: inout Int,
    remainingNodes: inout Int
  ) -> Bool {
    guard !message.content.isEmpty else {
      return false
    }
    var containsOutput = false
    for content in message.content {
      guard consumeNode(remainingNodes: &remainingNodes) else {
        return false
      }
      switch content {
      case .text(let text):
        guard
          !text.contains("\0"),
          consumeString(text, remainingBytes: &remainingBytes)
        else {
          return false
        }
        containsOutput = containsOutput || !text.isEmpty

      case .toolCall(let call):
        guard
          validateHistoricalToolCall(
            call,
            remainingBytes: &remainingBytes,
            remainingNodes: &remainingNodes
          ),
          seenToolCalls.insert(call.id).inserted
        else {
          return false
        }
        unresolvedToolCalls.insert(call.id)
        containsOutput = true

      case .image, .toolResult:
        return false
      }
    }
    return containsOutput
  }

  static func validateToolMessage(
    _ message: Message,
    unresolvedToolCalls: inout Set<ToolCallID>,
    remainingBytes: inout Int,
    remainingNodes: inout Int
  ) -> Bool {
    guard !message.content.isEmpty else {
      return false
    }
    for content in message.content {
      guard
        consumeNode(remainingNodes: &remainingNodes),
        case .toolResult(let result) = content,
        unresolvedToolCalls.remove(result.toolCallID) != nil,
        validateToolResult(
          result,
          remainingBytes: &remainingBytes,
          remainingNodes: &remainingNodes
        )
      else {
        return false
      }
    }
    return true
  }
}
