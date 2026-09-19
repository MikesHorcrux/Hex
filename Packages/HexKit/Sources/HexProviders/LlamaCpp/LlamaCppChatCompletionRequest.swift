import Foundation
import HexCore

struct LlamaCppChatCompletionRequest: Encodable, Sendable {
  let model: String
  let messages: [JSONValue]
  let stream: Bool
  let streamOptions: JSONValue
  let maxTokens: Int?
  let temperature: Double?
  let tools: [JSONValue]?
  let toolChoice: JSONValue?

  init(
    request: InferenceRequest,
    model: LlamaCppLocalModelConfiguration
  ) throws {
    self.model = request.modelID.rawValue
    self.messages = try Self.messages(request.messages)
    self.stream = true
    self.streamOptions = .object(["include_usage": .boolean(true)])
    self.maxTokens = request.options.maxOutputTokens ?? model.maximumOutputTokens
    self.temperature = request.options.temperature
    self.tools = request.tools.isEmpty ? nil : request.tools.map(Self.tool)
    self.toolChoice = request.tools.isEmpty ? nil : Self.toolChoice(request.toolChoice)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(model, forKey: .model)
    try container.encode(messages, forKey: .messages)
    try container.encode(stream, forKey: .stream)
    try container.encode(streamOptions, forKey: .streamOptions)
    try container.encodeIfPresent(maxTokens, forKey: .maxTokens)
    try container.encodeIfPresent(temperature, forKey: .temperature)
    try container.encodeIfPresent(tools, forKey: .tools)
    try container.encodeIfPresent(toolChoice, forKey: .toolChoice)
  }

  private enum CodingKeys: String, CodingKey {
    case model, messages, stream
    case streamOptions = "stream_options"
    case maxTokens = "max_tokens"
    case temperature, tools
    case toolChoice = "tool_choice"
  }

  /// Qwen's chat template accepts one leading instruction message. Hex intentionally keeps
  /// operating policy and self-knowledge as separate provider-neutral developer messages, so
  /// combine that leading instruction prefix at this adapter boundary without changing Hex's
  /// durable message model or tool-loop semantics.
  private static func messages(_ messages: [Message]) throws -> [JSONValue] {
    var prefix: [Message] = []
    var remainderStart = messages.startIndex
    while remainderStart < messages.endIndex {
      let message = messages[remainderStart]
      guard message.role == .system || message.role == .developer else { break }
      prefix.append(message)
      remainderStart = messages.index(after: remainderStart)
    }

    var normalized: [JSONValue] = []
    if !prefix.isEmpty {
      let instruction = prefix.flatMap { message in
        message.content.compactMap { content -> String? in
          guard case .text(let text) = content else { return nil }
          return text
        }
      }.joined(separator: "\n\n")
      normalized.append(
        try message(Message(role: .system, content: [.text(instruction)]))
      )
    }
    normalized.append(contentsOf: try messages[remainderStart...].map(Self.message))
    return normalized
  }

  private static func message(_ message: Message) throws -> JSONValue {
    var object: [String: JSONValue] = ["role": .string(message.role.rawValue)]
    var textParts: [String] = []
    var toolCalls: [JSONValue] = []
    var toolCallID: String?
    for content in message.content {
      switch content {
      case .text(let text):
        textParts.append(text)
      case .image:
        throw LlamaCppLocalInferenceProviderError.invalidRequest
      case .toolCall(let call):
        let arguments = try JSONEncoder().encode(JSONValue.object(call.arguments))
        toolCalls.append(
          .object([
            "id": .string(call.id.rawValue),
            "type": .string("function"),
            "function": .object([
              "name": .string(call.name),
              "arguments": .string(String(decoding: arguments, as: UTF8.self)),
            ]),
          ]))
      case .toolResult(let result):
        toolCallID = result.toolCallID.rawValue
        textParts.append(try jsonString(result.output))
        textParts.append(
          contentsOf: result.content.compactMap {
            if case .text(let text) = $0 { return text }
            return nil
          })
      }
    }
    object["content"] = .string(textParts.joined(separator: "\n"))
    if !toolCalls.isEmpty { object["tool_calls"] = .array(toolCalls) }
    if let toolCallID { object["tool_call_id"] = .string(toolCallID) }
    return .object(object)
  }

  private static func tool(_ tool: ToolDefinition) -> JSONValue {
    .object([
      "type": .string("function"),
      "function": .object([
        "name": .string(tool.name),
        "description": .string(tool.description),
        "parameters": .object(tool.inputSchema),
      ]),
    ])
  }

  private static func toolChoice(_ choice: ToolChoice) -> JSONValue {
    switch choice {
    case .automatic: return .string("auto")
    case .none: return .string("none")
    case .required: return .string("required")
    case .named(let name):
      return .object([
        "type": .string("function"),
        "function": .object(["name": .string(name)]),
      ])
    }
  }

  private static func jsonString(_ value: JSONValue) throws -> String {
    let data = try JSONEncoder().encode(value)
    return String(decoding: data, as: UTF8.self)
  }
}
