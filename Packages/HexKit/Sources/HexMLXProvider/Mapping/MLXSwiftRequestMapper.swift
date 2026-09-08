import Foundation
import HexCore
import HexProviders
import MLXLMCommon

enum MLXSwiftRequestMapper {
  static func messages(
    for request: InferenceRequest
  ) throws -> [MLXLMCommon.Chat.Message] {
    var result: [MLXLMCommon.Chat.Message] = []
    result.reserveCapacity(request.messages.count)

    for message in request.messages {
      switch message.role {
      case .system, .developer, .user:
        let text = try textOnlyContent(message.content)
        guard !text.isEmpty else {
          throw MLXLocalInferenceProviderError.invalidRequest
        }
        if message.role == .user {
          result.append(.user(text))
        } else {
          result.append(.system(text))
        }

      case .assistant:
        var textParts: [String] = []
        var toolCalls: [MLXLMCommon.ToolCall] = []
        for content in message.content {
          switch content {
          case .text(let text):
            textParts.append(text)
          case .toolCall(let call):
            toolCalls.append(try mlxToolCall(call))
          case .image, .toolResult:
            throw MLXLocalInferenceProviderError.invalidRequest
          }
        }
        guard !textParts.isEmpty || !toolCalls.isEmpty else {
          throw MLXLocalInferenceProviderError.invalidRequest
        }
        result.append(
          .assistant(
            textParts.joined(separator: "\n"),
            toolCalls: toolCalls.isEmpty ? nil : toolCalls
          )
        )

      case .tool:
        guard !message.content.isEmpty else {
          throw MLXLocalInferenceProviderError.invalidRequest
        }
        for content in message.content {
          guard case .toolResult(let toolResult) = content else {
            throw MLXLocalInferenceProviderError.invalidRequest
          }
          result.append(
            .tool(
              try toolResultText(toolResult),
              id: toolResult.toolCallID.rawValue
            )
          )
        }
      }
    }
    return result
  }

  static func toolSpecifications(
    for request: InferenceRequest
  ) throws -> [MLXLMCommon.ToolSpec]? {
    let definitions: [ToolDefinition]
    switch request.toolChoice {
    case .none:
      return nil
    case .named(let name):
      guard let definition = request.tools.first(where: { $0.name == name }) else {
        throw MLXLocalInferenceProviderError.invalidToolChoice
      }
      definitions = [definition]
    case .automatic, .required:
      definitions = request.tools
    }
    guard !definitions.isEmpty else {
      return nil
    }
    return try definitions.map { definition in
      let parameters = try sendableObject(definition.inputSchema)
      let function: [String: any Sendable] = [
        "name": definition.name,
        "description": definition.description,
        "parameters": parameters,
      ]
      return [
        "type": "function",
        "function": function,
      ]
    }
  }

  static func coreToolCall(
    _ toolCall: MLXLMCommon.ToolCall
  ) throws -> HexCore.ToolCall {
    let identifier: ToolCallID
    if let rawIdentifier = toolCall.id {
      guard
        !rawIdentifier.isEmpty,
        rawIdentifier.utf8.count <= 256,
        !rawIdentifier.contains("\0")
      else {
        throw MLXLocalInferenceProviderError.invalidStream
      }
      identifier = ToolCallID(rawValue: rawIdentifier)
    } else {
      identifier = ToolCallID()
    }
    return HexCore.ToolCall(
      id: identifier,
      name: toolCall.function.name,
      arguments: try toolCall.function.arguments.mapValues(coreJSONValue)
    )
  }

  private static func textOnlyContent(_ content: [MessageContent]) throws -> String {
    var textParts: [String] = []
    for part in content {
      guard case .text(let text) = part else {
        throw MLXLocalInferenceProviderError.invalidRequest
      }
      textParts.append(text)
    }
    return textParts.joined(separator: "\n")
  }

  private static func mlxToolCall(
    _ toolCall: HexCore.ToolCall
  ) throws -> MLXLMCommon.ToolCall {
    MLXLMCommon.ToolCall(
      function: .init(
        name: toolCall.name,
        arguments: try toolCall.arguments.mapValues(mlxJSONValue)
      ),
      id: toolCall.id.rawValue
    )
  }

  private static func toolResultText(_ result: ToolResult) throws -> String {
    guard
      result.content.allSatisfy({ item in
        if case .text = item {
          return true
        }
        return false
      })
    else {
      throw MLXLocalInferenceProviderError.invalidRequest
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(result)
    guard let text = String(data: data, encoding: .utf8) else {
      throw MLXLocalInferenceProviderError.invalidRequest
    }
    return text
  }

  private static func sendableObject(
    _ value: [String: HexCore.JSONValue]
  ) throws -> [String: any Sendable] {
    try value.mapValues(sendableValue)
  }

  private static func sendableValue(
    _ value: HexCore.JSONValue
  ) throws -> any Sendable {
    switch value {
    case .null:
      return NSNull()
    case .boolean(let value):
      return value
    case .integer(let value):
      return value
    case .number(let value):
      guard value.isFinite else {
        throw MLXLocalInferenceProviderError.invalidRequest
      }
      return value
    case .string(let value):
      return value
    case .array(let values):
      return try values.map(sendableValue)
    case .object(let values):
      return try sendableObject(values)
    }
  }

  private static func mlxJSONValue(
    _ value: HexCore.JSONValue
  ) throws -> MLXLMCommon.JSONValue {
    switch value {
    case .null:
      return .null
    case .boolean(let value):
      return .bool(value)
    case .integer(let value):
      guard let integer = Int(exactly: value) else {
        throw MLXLocalInferenceProviderError.invalidRequest
      }
      return .int(integer)
    case .number(let value):
      guard value.isFinite else {
        throw MLXLocalInferenceProviderError.invalidRequest
      }
      return .double(value)
    case .string(let value):
      return .string(value)
    case .array(let values):
      return .array(try values.map(mlxJSONValue))
    case .object(let values):
      return .object(try values.mapValues(mlxJSONValue))
    }
  }

  private static func coreJSONValue(
    _ value: MLXLMCommon.JSONValue
  ) throws -> HexCore.JSONValue {
    switch value {
    case .null:
      return .null
    case .bool(let value):
      return .boolean(value)
    case .int(let value):
      guard let integer = Int64(exactly: value) else {
        throw MLXLocalInferenceProviderError.invalidStream
      }
      return .integer(integer)
    case .double(let value):
      guard value.isFinite else {
        throw MLXLocalInferenceProviderError.invalidStream
      }
      if let integer = Int64(exactly: value) {
        return .integer(integer)
      }
      return .number(value)
    case .string(let value):
      return .string(value)
    case .array(let values):
      return .array(try values.map(coreJSONValue))
    case .object(let values):
      return .object(try values.mapValues(coreJSONValue))
    }
  }
}
