import Foundation
import HexCore

struct OpenAIResponsesInputEncoder: Sendable {
  let configuration: OpenAIResponsesConfiguration
  private var validation: OpenAIResponsesInputValidator { .init(configuration: configuration) }

  func mapMessages(_ messages: [Message]) throws -> [JSONValue] {
    var input: [JSONValue] = []
    for message in messages {
      try append(message, to: &input)
    }
    return input
  }

  func append(_ message: Message, to input: inout [JSONValue]) throws {
    var messageContent: [JSONValue] = []

    func flushMessageContent() throws {
      guard !messageContent.isEmpty else { return }
      guard message.role != .tool else {
        throw OpenAIResponsesProviderError.invalidRequest
      }
      input.append(
        .object([
          "type": .string("message"),
          // The ChatGPT subscription route rejects system messages. Developer messages
          // carry the same host-owned instructions on that route.
          "role": .string(
            configuration.service == .chatGPTCodexSubscription && message.role == .system
              ? "developer" : message.role.rawValue),
          "content": .array(messageContent),
        ])
      )
      messageContent.removeAll(keepingCapacity: true)
    }

    for content in message.content {
      switch content {
      case .text(let text):
        guard
          message.role != .tool,
          !text.isEmpty,
          text.utf8.count <= configuration.maximumInputValueBytes
        else {
          throw OpenAIResponsesProviderError.invalidRequest
        }
        messageContent.append(
          .object([
            "type": .string(message.role == .assistant ? "output_text" : "input_text"),
            "text": .string(text),
          ])
        )
      case .image(let image):
        guard message.role == .user else {
          throw OpenAIResponsesProviderError.invalidRequest
        }
        let imageURL = try validation.validatedImageURL(image)
        messageContent.append(
          .object([
            "type": .string("input_image"),
            "image_url": .string(imageURL),
            "detail": .string("auto"),
          ])
        )
      case .toolCall(let call):
        guard message.role == .assistant else {
          throw OpenAIResponsesProviderError.invalidRequest
        }
        try flushMessageContent()
        input.append(try mapToolCall(call))
      case .toolResult(let result):
        guard message.role == .tool else {
          throw OpenAIResponsesProviderError.invalidRequest
        }
        try flushMessageContent()
        input.append(try mapToolResult(result))
      }
    }
    try flushMessageContent()
  }

  func mapToolCall(_ call: ToolCall) throws -> JSONValue {
    try validation.validateToolCall(call)
    return .object([
      "type": .string("function_call"),
      "call_id": .string(call.id.rawValue),
      "name": .string(call.name),
      "arguments": .string(try encodeJSONObject(call.arguments)),
    ])
  }

  func mapToolResult(_ result: ToolResult) throws -> JSONValue {
    guard validation.isValidIdentifier(result.toolCallID.rawValue),
      result.hasValidNonExecutionMetadata
    else {
      throw OpenAIResponsesProviderError.invalidRequest
    }
    try ToolArtifactValidation.validate(result.artifacts)
    var outputFields: [String: JSONValue] = [
      "status": .string(result.status.rawValue),
      "output": result.output,
    ]
    if !result.artifacts.isEmpty { outputFields["artifacts"] = result.artifactDescriptions }
    if let reason = result.notExecutedReason {
      outputFields["execution"] = .string("not_executed")
      outputFields["not_executed_reason"] = .string(reason.rawValue)
    }
    let output = JSONValue.object(outputFields)
    guard
      OpenAIJSONValidator.measuredBytes(
        for: output,
        maximumDepth: configuration.maximumJSONDepth,
        maximumNodes: configuration.maximumJSONNodes,
        maximumStringBytes: configuration.maximumInputValueBytes
      ) != nil
    else {
      throw OpenAIResponsesProviderError.invalidRequest
    }
    let renderedOutput = try encodeJSON(output)
    let mappedOutput: JSONValue
    if result.content.isEmpty {
      mappedOutput = .string(renderedOutput)
    } else {
      var content: [JSONValue] = [
        .object([
          "type": .string("input_text"),
          "text": .string(renderedOutput),
        ])
      ]
      for richContent in result.content {
        switch richContent {
        case .text(let text):
          // MCP may return empty text after a successful action. The structured receipt above
          // still carries its status and verification requirement; omit only this empty block.
          guard !text.isEmpty else { continue }
          guard
            text.utf8.count <= configuration.maximumInputValueBytes
          else {
            throw OpenAIResponsesProviderError.invalidRequest
          }
          content.append(
            .object([
              "type": .string("input_text"),
              "text": .string(text),
            ])
          )
        case .image(let image):
          content.append(
            .object([
              "type": .string("input_image"),
              "image_url": .string(try validation.validatedImageURL(image)),
              "detail": .string("auto"),
            ])
          )
        }
      }
      mappedOutput = .array(content)
    }

    return .object([
      "type": .string("function_call_output"),
      "call_id": .string(result.toolCallID.rawValue),
      "output": mappedOutput,
    ])
  }

  func mapTools(_ tools: [ToolDefinition]) throws -> [JSONValue] {
    tools.map { tool in
      .object([
        "type": .string("function"),
        "name": .string(tool.name),
        "description": .string(tool.description),
        "parameters": .object(tool.inputSchema),
        // Responses otherwise attempts strict normalization, turning omitted optional inputs
        // into required fields. Preserve Hex's schemas and exact host argument validation.
        "strict": .boolean(false),
      ])
    }
  }

  func mapToolChoice(_ choice: ToolChoice) throws -> JSONValue {
    switch choice {
    case .automatic:
      .string("auto")
    case .none:
      .string("none")
    case .required:
      .string("required")
    case .named(let name):
      .object([
        "type": .string("function"),
        "name": .string(name),
      ])
    }
  }

  func encodeJSONObject(_ object: [String: JSONValue]) throws -> String {
    try encodeJSON(.object(object))
  }

  func encodeJSON(_ value: JSONValue) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data: Data
    do {
      data = try encoder.encode(value)
    } catch {
      throw OpenAIResponsesProviderError.invalidRequest
    }
    guard
      data.count <= configuration.maximumInputValueBytes,
      let string = String(data: data, encoding: .utf8)
    else {
      throw OpenAIResponsesProviderError.invalidRequest
    }
    return string
  }
}
