import Foundation
import HexCore

/// Provider for the OpenAI-compatible chat-completions stream exposed by Prism llama-server.
/// The server is intentionally an external local process: Hex owns the agent loop and tools, while
/// Prism owns GGUF loading and Metal execution.
public actor LlamaCppLocalInferenceProvider: InferenceProvider {
  public nonisolated let descriptor: ProviderDescriptor
  private let configuration: LlamaCppLocalProviderConfiguration
  private let session: URLSession
  private var activeRequestID: InferenceRequestID?

  public init(
    configuration: LlamaCppLocalProviderConfiguration,
    session: URLSession = .shared
  ) {
    self.configuration = configuration
    self.session = session
    var capabilities: Set<InferenceCapability> = [.textInput, .streaming]
    if let model = configuration.models.first {
      if model.supportsToolCalling { capabilities.insert(.toolCalling) }
      if model.supportsParallelToolCalling { capabilities.insert(.parallelToolCalling) }
    }
    descriptor = ProviderDescriptor(
      id: configuration.providerID,
      displayName: configuration.displayName,
      capabilities: capabilities
    )
  }

  public func availableModels() async throws -> [ModelDescriptor] {
    try Task.checkCancellation()
    return configuration.models.map { model in
      var capabilities: Set<InferenceCapability> = [.textInput, .streaming]
      if model.supportsToolCalling { capabilities.insert(.toolCalling) }
      if model.supportsParallelToolCalling { capabilities.insert(.parallelToolCalling) }
      return ModelDescriptor(
        id: model.modelID,
        providerID: configuration.providerID,
        displayName: model.displayName,
        capabilities: capabilities,
        contextWindow: model.contextWindow,
        maxOutputTokens: model.maximumOutputTokens
      )
    }
  }

  public func stream(_ request: InferenceRequest) async throws -> InferenceStream {
    try Task.checkCancellation()
    guard request.previousProviderResponseID == nil else {
      throw LlamaCppLocalInferenceProviderError.unsupportedContinuation
    }
    guard let model = configuration.models.first(where: { $0.modelID == request.modelID }) else {
      throw LlamaCppLocalInferenceProviderError.invalidRequest
    }
    guard request.providerID == configuration.providerID, activeRequestID == nil else {
      throw activeRequestID == nil
        ? LlamaCppLocalInferenceProviderError.invalidRequest
        : LlamaCppLocalInferenceProviderError.busy
    }
    try validate(request, model: model)
    let body = try LlamaCppChatCompletionRequest(request: request, model: model)
    var urlRequest = URLRequest(url: endpointURL())
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = configuration.requestTimeout
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    urlRequest.httpBody = try JSONEncoder().encode(body)
    activeRequestID = request.id

    let (events, continuation) = AsyncThrowingStream.makeStream(
      of: InferenceStreamEvent.self,
      throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(configuration.maximumBufferedEvents)
    )
    let session = self.session
    let producer = Task { [weak self] in
      do {
        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
          throw LlamaCppLocalInferenceProviderError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
          throw LlamaCppLocalInferenceProviderError.httpFailure(httpResponse.statusCode)
        }
        try await Self.consume(
          bytes: bytes,
          request: request,
          continuation: continuation
        )
        continuation.finish()
      } catch is CancellationError {
        continuation.finish(throwing: CancellationError())
      } catch let error as LlamaCppLocalInferenceProviderError {
        continuation.finish(throwing: error)
      } catch {
        continuation.finish(throwing: Task.isCancelled
          ? CancellationError()
          : LlamaCppLocalInferenceProviderError.transportFailed)
      }
      await self?.finish(request.id)
    }
    return InferenceStream(
      events: events,
      onCancellation: { producer.cancel() },
      waitForTermination: { await producer.value }
    )
  }

  private func endpointURL() -> URL {
    configuration.endpoint.appendingPathComponent("v1/chat/completions")
  }

  private func finish(_ requestID: InferenceRequestID) {
    if activeRequestID == requestID { activeRequestID = nil }
  }

  private func validate(
    _ request: InferenceRequest,
    model: LlamaCppLocalModelConfiguration
  ) throws {
    guard
      request.modelID == model.modelID,
      request.options.maxOutputTokens.map({ $0 > 0 && $0 <= model.maximumOutputTokens }) ?? true,
      request.options.temperature.map({ $0.isFinite && (0...2).contains($0) }) ?? true
    else { throw LlamaCppLocalInferenceProviderError.invalidRequest }
    if !request.tools.isEmpty && !model.supportsToolCalling {
      throw LlamaCppLocalInferenceProviderError.invalidRequest
    }
    if !model.supportsParallelToolCalling,
      case .automatic = request.toolChoice,
      request.tools.count > 1
    {
      // Automatic choice is still valid; the model may choose one call. The runtime validates the
      // actual number of emitted calls before dispatching them.
    }
    for message in request.messages {
      for content in message.content {
        if case .image = content {
          throw LlamaCppLocalInferenceProviderError.invalidRequest
        }
      }
    }
  }

  private nonisolated static func consume(
    bytes: URLSession.AsyncBytes,
    request: InferenceRequest,
    continuation: AsyncThrowingStream<InferenceStreamEvent, any Error>.Continuation
  ) async throws {
    var responseID: String?
    var pendingToolCalls: [Int: PendingToolCall] = [:]
    var terminalReason: InferenceStopReason = .stop
    var usage: InferenceUsage?

    try yield(.started(providerResponseID: nil), to: continuation)
    var line = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      line.append(byte)
      guard line.count <= 8 * 1_024 * 1_024 else {
        throw LlamaCppLocalInferenceProviderError.invalidStream
      }
      guard byte == 0x0A else { continue }
      let rawLine = String(decoding: line, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      line.removeAll(keepingCapacity: true)
      guard rawLine.hasPrefix("data:") else { continue }
      let payload = rawLine.dropFirst(5).trimmingCharacters(in: .whitespaces)
      if payload == "[DONE]" {
        break
      }
      guard let data = payload.data(using: .utf8) else {
        throw LlamaCppLocalInferenceProviderError.invalidStream
      }
      let chunk: LlamaCppChatCompletionChunk
      do {
        chunk = try JSONDecoder().decode(LlamaCppChatCompletionChunk.self, from: data)
      } catch {
        throw LlamaCppLocalInferenceProviderError.invalidStream
      }
      if responseID == nil { responseID = chunk.id }
      if let chunkUsage = chunk.usage {
        usage = InferenceUsage(
          inputTokens: UInt64(max(0, chunkUsage.promptTokens)),
          outputTokens: UInt64(max(0, chunkUsage.completionTokens)),
          cachedInputTokens: 0,
          reasoningTokens: 0
        )
      }
      for choice in chunk.choices {
        if let text = choice.delta.content, !text.isEmpty {
          try yield(.textDelta(text), to: continuation)
        }
        if let reasoning = choice.delta.reasoningContent, !reasoning.isEmpty {
          try yield(.reasoningSummaryDelta(reasoning), to: continuation)
        }
        if let reasoning = choice.delta.reasoning, !reasoning.isEmpty {
          try yield(.reasoningSummaryDelta(reasoning), to: continuation)
        }
        for call in choice.delta.toolCalls ?? [] {
          let index = call.index ?? pendingToolCalls.count
          var pending = pendingToolCalls[index] ?? PendingToolCall()
          if let id = call.id, !id.isEmpty { pending.id = id }
          if let name = call.function?.name, !name.isEmpty { pending.name += name }
          if let arguments = call.function?.arguments { pending.arguments += arguments }
          guard pending.name.utf8.count <= 256, pending.arguments.utf8.count <= 16 * 1_024 * 1_024
          else { throw LlamaCppLocalInferenceProviderError.invalidStream }
          pendingToolCalls[index] = pending
        }
        if let finishReason = choice.finishReason {
          terminalReason = mapStopReason(finishReason)
        }
      }
    }
    for index in pendingToolCalls.keys.sorted() {
      guard let pending = pendingToolCalls[index], !pending.name.isEmpty else {
        throw LlamaCppLocalInferenceProviderError.invalidStream
      }
      guard let argumentsData = pending.arguments.data(using: .utf8) else {
        throw LlamaCppLocalInferenceProviderError.invalidStream
      }
      let arguments: [String: JSONValue]
      do {
        let value = try JSONDecoder().decode(JSONValue.self, from: argumentsData)
        guard case .object(let object) = value else {
          throw LlamaCppLocalInferenceProviderError.invalidStream
        }
        arguments = object
      } catch let error as LlamaCppLocalInferenceProviderError {
        throw error
      } catch {
        throw LlamaCppLocalInferenceProviderError.invalidStream
      }
      try yield(
        .toolCall(ToolCall(
          id: ToolCallID(rawValue: pending.id.isEmpty ? UUID().uuidString : pending.id),
          name: pending.name,
          arguments: arguments
        )),
        to: continuation
      )
      terminalReason = .toolCalls
    }
    try yield(.usage(usage ?? InferenceUsage(inputTokens: 0, outputTokens: 0)), to: continuation)
    try yield(.completed(terminalReason), to: continuation)
    _ = responseID
  }

  private nonisolated static func mapStopReason(_ reason: String) -> InferenceStopReason {
    switch reason {
    case "tool_calls", "function_call": return .toolCalls
    case "length": return .length
    case "content_filter": return .contentFilter
    default: return .stop
    }
  }

  private nonisolated static func yield(
    _ event: InferenceStreamEvent,
    to continuation: AsyncThrowingStream<InferenceStreamEvent, any Error>.Continuation
  ) throws {
    switch continuation.yield(event) {
    case .enqueued: return
    case .dropped, .terminated:
      throw CancellationError()
    @unknown default:
      throw CancellationError()
    }
  }
}

private struct PendingToolCall: Sendable {
  var id = ""
  var name = ""
  var arguments = ""
}

private struct LlamaCppChatCompletionRequest: Encodable, Sendable {
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
        toolCalls.append(.object([
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
        textParts.append(contentsOf: result.content.compactMap {
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

private struct LlamaCppChatCompletionChunk: Decodable, Sendable {
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
