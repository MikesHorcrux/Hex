import Foundation
import HexCore

extension MLXRequestContentValidator {
  static func validateHistoricalToolCall(
    _ call: ToolCall,
    remainingBytes: inout Int,
    remainingNodes: inout Int
  ) -> Bool {
    guard
      isValidToolCallID(call.id),
      isValidToolName(call.name),
      consumeString(call.id.rawValue, remainingBytes: &remainingBytes),
      consumeString(call.name, remainingBytes: &remainingBytes),
      validateJSONObject(
        call.arguments,
        maximumBytes: 2 * 1_024 * 1_024,
        remainingBytes: &remainingBytes,
        remainingNodes: &remainingNodes
      )
    else {
      return false
    }
    return true
  }

  static func validateToolResult(
    _ result: ToolResult,
    remainingBytes: inout Int,
    remainingNodes: inout Int
  ) -> Bool {
    guard
      isValidToolCallID(result.toolCallID),
      consumeString(result.toolCallID.rawValue, remainingBytes: &remainingBytes),
      validateJSONValue(
        result.output,
        maximumBytes: 8 * 1_024 * 1_024,
        remainingBytes: &remainingBytes,
        remainingNodes: &remainingNodes
      )
    else {
      return false
    }
    for content in result.content {
      guard
        consumeNode(remainingNodes: &remainingNodes),
        case .text(let text) = content,
        !text.contains("\0"),
        consumeString(text, remainingBytes: &remainingBytes)
      else {
        return false
      }
    }
    return true
  }

  static func validateToolDefinition(
    _ definition: ToolDefinition,
    remainingBytes: inout Int,
    remainingNodes: inout Int
  ) -> Bool {
    guard
      isValidToolName(definition.name),
      !definition.description.isEmpty,
      definition.description.utf8.count <= 4_096,
      !definition.description.contains("\0"),
      consumeString(definition.name, remainingBytes: &remainingBytes),
      consumeString(definition.description, remainingBytes: &remainingBytes),
      validateJSONObject(
        definition.inputSchema,
        maximumBytes: 64 * 1_024,
        remainingBytes: &remainingBytes,
        remainingNodes: &remainingNodes
      ),
      let schema = try? JSONEncoder().encode(definition.inputSchema),
      schema.count <= 64 * 1_024
    else {
      return false
    }
    return true
  }

  static func isValidToolCallID(_ id: ToolCallID) -> Bool {
    !id.rawValue.isEmpty
      && id.rawValue.utf8.count <= 256
      && !id.rawValue.contains("\0")
  }

  static func isValidToolName(_ name: String) -> Bool {
    !name.isEmpty
      && name.utf8.count <= 128
      && !name.contains("\0")
  }
}
