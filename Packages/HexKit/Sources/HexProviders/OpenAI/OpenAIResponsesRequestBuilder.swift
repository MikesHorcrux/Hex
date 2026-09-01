import Foundation
import HexCore

struct OpenAIResponsesRequestBuilder {
  private let configuration: OpenAIResponsesConfiguration

  init(configuration: OpenAIResponsesConfiguration) {
    self.configuration = configuration
  }

  func build(
    _ request: InferenceRequest,
    serverState: OpenAIServerContinuationState?,
    localState: OpenAILocalContinuationState?
  ) throws -> OpenAIResponsesRequestPlan {
    let model = try validatedModel(for: request)
    try validateRequestShape(request, model: model)
    let messageFingerprints: [OpenAIMessageFingerprint]
    do {
      messageFingerprints = try request.messages.map(OpenAIMessageFingerprint.make)
    } catch {
      throw OpenAIResponsesProviderError.invalidRequest
    }

    let input: [JSONValue]
    switch configuration.privacyMode {
    case .serverManagedContinuation:
      guard localState == nil else {
        throw OpenAIResponsesProviderError.invalidRequest
      }
      if request.previousProviderResponseID == nil {
        guard serverState == nil else {
          throw OpenAIResponsesProviderError.invalidRequest
        }
        input = try mapMessages(request.messages)
      } else {
        guard let serverState else {
          throw OpenAIResponsesProviderError.invalidRequest
        }
        input = try mapServerContinuation(request.messages, state: serverState)
      }
    case .localEphemeralReplay:
      guard serverState == nil else {
        throw OpenAIResponsesProviderError.invalidRequest
      }
      if request.previousProviderResponseID == nil {
        guard localState == nil else {
          throw OpenAIResponsesProviderError.invalidRequest
        }
        input = try mapMessages(request.messages)
      } else {
        guard let localState else {
          throw OpenAIResponsesProviderError.missingLocalContinuation
        }
        input = try mapLocalReplay(request.messages, state: localState)
      }
    }

    guard !input.isEmpty else {
      throw OpenAIResponsesProviderError.invalidRequest
    }

    var body: [String: JSONValue] = [
      "model": .string(request.modelID.rawValue),
      "input": .array(input),
      "stream": .boolean(true),
      "store": .boolean(configuration.privacyMode == .serverManagedContinuation),
    ]

    if configuration.privacyMode == .serverManagedContinuation,
      let previousResponseID = request.previousProviderResponseID
    {
      body["previous_response_id"] = .string(previousResponseID)
    }

    if configuration.privacyMode == .localEphemeralReplay {
      body["include"] = .array([.string("reasoning.encrypted_content")])
    }

    if !request.tools.isEmpty {
      body["tools"] = .array(try mapTools(request.tools))
      body["parallel_tool_calls"] = .boolean(
        model.capabilities.contains(.parallelToolCalling)
      )
    }
    body["tool_choice"] = try mapToolChoice(request.toolChoice)

    if configuration.requestReasoningSummaries,
      model.capabilities.contains(.reasoningSummary)
    {
      body["reasoning"] = .object(["summary": .string("auto")])
    }

    if let maxOutputTokens = request.options.maxOutputTokens {
      body["max_output_tokens"] = .integer(Int64(maxOutputTokens))
    }
    if let temperature = request.options.temperature {
      if let integralTemperature = Int64(exactly: temperature) {
        body["temperature"] = .integer(integralTemperature)
      } else {
        body["temperature"] = .number(temperature)
      }
    }

    let bodyValue = JSONValue.object(body)
    guard
      OpenAIJSONValidator.measuredBytes(
        for: bodyValue,
        maximumDepth: configuration.maximumJSONDepth,
        maximumNodes: configuration.maximumJSONNodes,
        maximumStringBytes: configuration.maximumRequestBodyBytes
      ) != nil
    else {
      throw OpenAIResponsesProviderError.invalidRequest
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bodyData: Data
    do {
      bodyData = try encoder.encode(bodyValue)
    } catch {
      throw OpenAIResponsesProviderError.invalidRequest
    }
    guard bodyData.count <= configuration.maximumRequestBodyBytes else {
      throw OpenAIResponsesProviderError.invalidRequest
    }

    return OpenAIResponsesRequestPlan(
      body: bodyData,
      priorServerState: serverState,
      priorLocalState: localState,
      currentMessageIDs: request.messages.map(\.id),
      currentMessageFingerprints: messageFingerprints,
      allowsParallelToolCalls: model.capabilities.contains(.parallelToolCalling)
    )
  }

  private func validatedModel(for request: InferenceRequest) throws -> ModelDescriptor {
    guard request.providerID == configuration.providerID else {
      throw OpenAIResponsesProviderError.invalidRequest
    }
    guard let model = configuration.models.first(where: { $0.id == request.modelID }) else {
      throw OpenAIResponsesProviderError.unsupportedModel
    }
    return model
  }

  private func validateRequestShape(
    _ request: InferenceRequest,
    model: ModelDescriptor
  ) throws {
    guard
      request.messages.count <= configuration.maximumMessages,
      request.tools.count <= configuration.maximumTools,
      isValidIdentifier(request.modelID.rawValue),
      request.previousProviderResponseID.map(isValidIdentifier) ?? true
    else {
      throw OpenAIResponsesProviderError.invalidRequest
    }

    guard model.capabilities.contains(.streaming) else {
      throw OpenAIResponsesProviderError.invalidRequest
    }

    var messageIDs = Set<MessageID>()
    var contentCount = 0
    var inputByteBudget = 0
    var containsImage = false
    for message in request.messages {
      guard messageIDs.insert(message.id).inserted, !message.content.isEmpty else {
        throw OpenAIResponsesProviderError.invalidRequest
      }
      let (newCount, overflowed) = contentCount.addingReportingOverflow(message.content.count)
      guard !overflowed, newCount <= configuration.maximumJSONNodes else {
        throw OpenAIResponsesProviderError.invalidRequest
      }
      contentCount = newCount

      for content in message.content {
        switch content {
        case .text(let text):
          try addToInputBudget(text.utf8.count, total: &inputByteBudget)
        case .image(let image):
          containsImage = true
          try addToInputBudget(image.sourceURL.absoluteString.utf8.count, total: &inputByteBudget)
          try addToInputBudget(image.mediaType.utf8.count, total: &inputByteBudget)
        case .toolCall(let call):
          try addToInputBudget(call.id.rawValue.utf8.count, total: &inputByteBudget)
          try addToInputBudget(call.name.utf8.count, total: &inputByteBudget)
          guard
            let measured = OpenAIJSONValidator.measuredBytes(
              for: .object(call.arguments),
              maximumDepth: configuration.maximumJSONDepth,
              maximumNodes: configuration.maximumJSONNodes,
              maximumStringBytes: configuration.maximumInputValueBytes
            )
          else {
            throw OpenAIResponsesProviderError.invalidRequest
          }
          try addToInputBudget(measured, total: &inputByteBudget)
        case .toolResult(let result):
          try addToInputBudget(result.toolCallID.rawValue.utf8.count, total: &inputByteBudget)
          guard
            let measured = OpenAIJSONValidator.measuredBytes(
              for: result.output,
              maximumDepth: configuration.maximumJSONDepth,
              maximumNodes: configuration.maximumJSONNodes,
              maximumStringBytes: configuration.maximumInputValueBytes
            )
          else {
            throw OpenAIResponsesProviderError.invalidRequest
          }
          try addToInputBudget(measured, total: &inputByteBudget)
          let (newContentCount, contentOverflow) = contentCount.addingReportingOverflow(
            result.content.count
          )
          guard
            !contentOverflow,
            newContentCount <= configuration.maximumJSONNodes
          else {
            throw OpenAIResponsesProviderError.invalidRequest
          }
          contentCount = newContentCount
          for richContent in result.content {
            switch richContent {
            case .text(let text):
              guard
                !text.isEmpty,
                text.utf8.count <= configuration.maximumInputValueBytes
              else {
                throw OpenAIResponsesProviderError.invalidRequest
              }
              try addToInputBudget(text.utf8.count, total: &inputByteBudget)
            case .image(let image):
              containsImage = true
              let imageURL = try validatedImageURL(image)
              try addToInputBudget(imageURL.utf8.count, total: &inputByteBudget)
              try addToInputBudget(image.mediaType.utf8.count, total: &inputByteBudget)
            }
          }
        }
      }
    }

    if containsImage {
      guard model.capabilities.contains(.imageInput) else {
        throw OpenAIResponsesProviderError.invalidRequest
      }
    }

    if request.messages.contains(where: { message in
      message.content.contains(where: { content in
        switch content {
        case .text:
          return true
        case .image, .toolCall, .toolResult:
          return false
        }
      })
    }) {
      guard model.capabilities.contains(.textInput) else {
        throw OpenAIResponsesProviderError.invalidRequest
      }
    }

    if request.messages.contains(where: { message in
      message.content.contains(where: { content in
        switch content {
        case .toolCall, .toolResult:
          return true
        case .text, .image:
          return false
        }
      })
    }) {
      guard model.capabilities.contains(.toolCalling) else {
        throw OpenAIResponsesProviderError.invalidRequest
      }
    }

    if !request.tools.isEmpty {
      guard model.capabilities.contains(.toolCalling) else {
        throw OpenAIResponsesProviderError.invalidRequest
      }
    }

    if let maximum = request.options.maxOutputTokens {
      guard maximum > 0, model.maxOutputTokens.map({ maximum <= $0 }) ?? true else {
        throw OpenAIResponsesProviderError.invalidRequest
      }
    }
    if let temperature = request.options.temperature {
      guard temperature.isFinite, (0...2).contains(temperature) else {
        throw OpenAIResponsesProviderError.invalidRequest
      }
    }

    var toolNames = Set<String>()
    for tool in request.tools {
      let schemaValue = JSONValue.object(tool.inputSchema)
      guard
        let schemaBytes = OpenAIJSONValidator.measuredBytes(
          for: schemaValue,
          maximumDepth: configuration.maximumJSONDepth,
          maximumNodes: configuration.maximumJSONNodes,
          maximumStringBytes: configuration.maximumInputValueBytes
        )
      else {
        throw OpenAIResponsesProviderError.invalidRequest
      }
      guard
        isValidToolName(tool.name),
        toolNames.insert(tool.name).inserted,
        !tool.description.isEmpty,
        tool.description.utf8.count <= configuration.maximumInputValueBytes,
        schemaBytes <= configuration.maximumInputValueBytes
      else {
        throw OpenAIResponsesProviderError.invalidRequest
      }
      try addToInputBudget(tool.name.utf8.count, total: &inputByteBudget)
      try addToInputBudget(tool.description.utf8.count, total: &inputByteBudget)
      try addToInputBudget(schemaBytes, total: &inputByteBudget)
    }

    switch request.toolChoice {
    case .automatic, .none:
      break
    case .required:
      guard !request.tools.isEmpty else {
        throw OpenAIResponsesProviderError.invalidRequest
      }
    case .named(let name):
      guard isValidToolName(name), toolNames.contains(name) else {
        throw OpenAIResponsesProviderError.invalidRequest
      }
    }
  }

  private func mapMessages(_ messages: [Message]) throws -> [JSONValue] {
    var input: [JSONValue] = []
    for message in messages {
      try append(message, to: &input)
    }
    return input
  }

  private func append(_ message: Message, to input: inout [JSONValue]) throws {
    var messageContent: [JSONValue] = []

    func flushMessageContent() throws {
      guard !messageContent.isEmpty else { return }
      guard message.role != .tool else {
        throw OpenAIResponsesProviderError.invalidRequest
      }
      input.append(
        .object([
          "type": .string("message"),
          "role": .string(message.role.rawValue),
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
            "type": .string("input_text"),
            "text": .string(text),
          ])
        )
      case .image(let image):
        guard message.role == .user else {
          throw OpenAIResponsesProviderError.invalidRequest
        }
        let imageURL = try validatedImageURL(image)
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

  private func mapServerContinuation(
    _ messages: [Message],
    state: OpenAIServerContinuationState
  ) throws -> [JSONValue] {
    do {
      try validateKnownHistory(
        messages,
        knownMessageIDs: state.knownMessageIDs,
        knownMessageFingerprints: state.knownMessageFingerprints
      )
      let tail = Array(messages.dropFirst(state.knownMessageIDs.count))
      let mirror = try assistantMirror(in: state.outputItems)
      if mirror.calls.isEmpty {
        guard
          tail.count == 2,
          tail[0].role == .assistant,
          tail[1].role == .user
        else {
          throw OpenAIResponsesProviderError.localContinuationMismatch
        }
        try validateAssistantMessage(tail[0], matches: mirror)
        var mapped: [JSONValue] = []
        try append(tail[1], to: &mapped)
        guard
          !mapped.isEmpty,
          mapped.allSatisfy({ item in
            guard case .object(let object) = item else { return false }
            return object["type"] == .string("message")
          })
        else {
          throw OpenAIResponsesProviderError.localContinuationMismatch
        }
        return mapped
      }
      return try mapToolContinuation(tail, expectedMirror: mirror)
    } catch {
      throw OpenAIResponsesProviderError.invalidRequest
    }
  }

  private func mapLocalReplay(
    _ messages: [Message],
    state: OpenAILocalContinuationState
  ) throws -> [JSONValue] {
    guard
      state.baseMessageCount <= state.knownMessageIDs.count,
      state.replaySegments.count <= configuration.maximumReplaySegments
    else {
      throw OpenAIResponsesProviderError.localContinuationMismatch
    }
    try validateKnownHistory(
      messages,
      knownMessageIDs: state.knownMessageIDs,
      knownMessageFingerprints: state.knownMessageFingerprints
    )

    var input = try mapMessages(Array(messages.prefix(state.baseMessageCount)))
    var messageCursor = state.baseMessageCount
    var priorOutputItems: [JSONValue]?

    for segment in state.replaySegments {
      guard
        segment.afterMessageCount >= messageCursor,
        segment.afterMessageCount <= messages.count,
        segment.outputItems.count <= configuration.maximumOutputItems
      else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }

      if segment.afterMessageCount > messageCursor {
        guard let priorOutputItems else {
          throw OpenAIResponsesProviderError.localContinuationMismatch
        }
        let expectedMirror = try assistantMirror(in: priorOutputItems)
        input.append(
          contentsOf: try mapToolContinuation(
            Array(messages[messageCursor..<segment.afterMessageCount]),
            expectedMirror: expectedMirror
          )
        )
      }

      input.append(contentsOf: segment.outputItems)
      priorOutputItems = segment.outputItems
      messageCursor = segment.afterMessageCount
    }

    guard let priorOutputItems else {
      throw OpenAIResponsesProviderError.localContinuationMismatch
    }
    let expectedMirror = try assistantMirror(in: priorOutputItems)
    input.append(
      contentsOf: try mapToolContinuation(
        Array(messages[messageCursor...]),
        expectedMirror: expectedMirror
      )
    )
    return input
  }

  private func mapToolContinuation(
    _ messages: [Message],
    expectedMirror: OpenAIAssistantMirror
  ) throws -> [JSONValue] {
    guard
      messages.count >= 2,
      messages[0].role == .assistant,
      !expectedMirror.calls.isEmpty
    else {
      throw OpenAIResponsesProviderError.localContinuationMismatch
    }
    try validateAssistantMessage(messages[0], matches: expectedMirror)

    var expectedByID: [ToolCallID: ToolCall] = [:]
    for call in expectedMirror.calls {
      guard expectedByID.updateValue(call, forKey: call.id) == nil else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
    }

    var resultIDs = Set<ToolCallID>()
    var output: [JSONValue] = []
    for message in messages.dropFirst() {
      guard message.role == .tool, !message.content.isEmpty else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
      for content in message.content {
        guard case .toolResult(let result) = content else {
          throw OpenAIResponsesProviderError.localContinuationMismatch
        }
        guard
          expectedByID[result.toolCallID] != nil,
          resultIDs.insert(result.toolCallID).inserted
        else {
          throw OpenAIResponsesProviderError.localContinuationMismatch
        }
        output.append(try mapToolResult(result))
      }
    }

    let expectedIDs = Set(expectedByID.keys)
    guard resultIDs == expectedIDs else {
      throw OpenAIResponsesProviderError.localContinuationMismatch
    }
    return output
  }

  private func validateAssistantMessage(
    _ message: Message,
    matches expected: OpenAIAssistantMirror
  ) throws {
    guard message.role == .assistant, !message.content.isEmpty else {
      throw OpenAIResponsesProviderError.localContinuationMismatch
    }
    var text = ""
    var textByteCount = 0
    var calls: [ToolCall] = []
    for content in message.content {
      switch content {
      case .text(let value):
        let (newByteCount, overflowed) = textByteCount.addingReportingOverflow(
          value.utf8.count
        )
        guard !overflowed, newByteCount <= configuration.maximumInputValueBytes else {
          throw OpenAIResponsesProviderError.localContinuationMismatch
        }
        text.append(value)
        textByteCount = newByteCount
      case .toolCall(let call):
        try validateToolCall(call)
        calls.append(call)
      case .image, .toolResult:
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
    }
    guard text == expected.text else {
      throw OpenAIResponsesProviderError.localContinuationMismatch
    }
    var actualByID: [ToolCallID: ToolCall] = [:]
    for call in calls {
      guard actualByID.updateValue(call, forKey: call.id) == nil else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
    }
    var expectedByID: [ToolCallID: ToolCall] = [:]
    for call in expected.calls {
      guard expectedByID.updateValue(call, forKey: call.id) == nil else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
    }
    guard actualByID == expectedByID else {
      throw OpenAIResponsesProviderError.localContinuationMismatch
    }
  }

  private func assistantMirror(in outputItems: [JSONValue]) throws -> OpenAIAssistantMirror {
    var text = ""
    var textByteCount = 0
    var calls: [ToolCall] = []
    for item in outputItems {
      guard case .object(let object) = item else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
      let itemType: String
      guard case .string(let resolvedType)? = object["type"] else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
      itemType = resolvedType
      if itemType == "reasoning" {
        continue
      }
      if itemType == "message" {
        guard
          object["role"] == .string("assistant"),
          case .array(let content)? = object["content"]
        else {
          throw OpenAIResponsesProviderError.localContinuationMismatch
        }
        for value in content {
          guard
            case .object(let part) = value,
            case .string(let partType)? = part["type"]
          else {
            throw OpenAIResponsesProviderError.localContinuationMismatch
          }
          let valueKey: String
          switch partType {
          case "output_text":
            valueKey = "text"
          case "refusal":
            valueKey = "refusal"
          default:
            throw OpenAIResponsesProviderError.localContinuationMismatch
          }
          guard case .string(let value)? = part[valueKey] else {
            throw OpenAIResponsesProviderError.localContinuationMismatch
          }
          let (newByteCount, overflowed) = textByteCount.addingReportingOverflow(
            value.utf8.count
          )
          guard !overflowed, newByteCount <= configuration.maximumInputValueBytes else {
            throw OpenAIResponsesProviderError.localContinuationMismatch
          }
          text.append(value)
          textByteCount = newByteCount
        }
        continue
      }
      guard itemType == "function_call" else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
      guard
        case .string(let callID)? = object["call_id"],
        case .string(let name)? = object["name"],
        case .string(let arguments)? = object["arguments"]
      else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
      let argumentData = Data(arguments.utf8)
      guard argumentData.count <= configuration.maximumToolArgumentBytes else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
      let decoded: JSONValue
      do {
        try OpenAIJSONStructuralPreflight.validateObjectRoot(
          argumentData,
          maximumDepth: configuration.maximumJSONDepth,
          maximumNodes: configuration.maximumJSONNodes
        )
        decoded = try JSONDecoder().decode(JSONValue.self, from: argumentData)
      } catch {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
      guard case .object(let argumentObject) = decoded else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
      let call = ToolCall(id: ToolCallID(rawValue: callID), name: name, arguments: argumentObject)
      try validateToolCall(call)
      calls.append(call)
    }
    guard !text.isEmpty || !calls.isEmpty else {
      throw OpenAIResponsesProviderError.localContinuationMismatch
    }
    return OpenAIAssistantMirror(text: text, calls: calls)
  }

  private func validateKnownHistory(
    _ messages: [Message],
    knownMessageIDs: [MessageID],
    knownMessageFingerprints: [OpenAIMessageFingerprint]
  ) throws {
    guard
      messages.count >= knownMessageIDs.count,
      knownMessageFingerprints.count == knownMessageIDs.count,
      Array(messages.prefix(knownMessageIDs.count).map(\.id)) == knownMessageIDs
    else {
      throw OpenAIResponsesProviderError.localContinuationMismatch
    }
    let fingerprints: [OpenAIMessageFingerprint]
    do {
      fingerprints = try messages.prefix(knownMessageIDs.count).map(
        OpenAIMessageFingerprint.make
      )
    } catch {
      throw OpenAIResponsesProviderError.localContinuationMismatch
    }
    guard fingerprints == knownMessageFingerprints else {
      throw OpenAIResponsesProviderError.localContinuationMismatch
    }
  }

  private func mapToolCall(_ call: ToolCall) throws -> JSONValue {
    try validateToolCall(call)
    return .object([
      "type": .string("function_call"),
      "call_id": .string(call.id.rawValue),
      "name": .string(call.name),
      "arguments": .string(try encodeJSONObject(call.arguments)),
    ])
  }

  private func mapToolResult(_ result: ToolResult) throws -> JSONValue {
    guard isValidIdentifier(result.toolCallID.rawValue) else {
      throw OpenAIResponsesProviderError.invalidRequest
    }
    let output = JSONValue.object([
      "status": .string(result.status.rawValue),
      "output": result.output,
    ])
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
          guard
            !text.isEmpty,
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
              "image_url": .string(try validatedImageURL(image)),
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

  private func validatedImageURL(_ image: ImageContent) throws -> String {
    let mediaType = image.mediaType.lowercased()
    guard
      image.mediaType == mediaType,
      ["image/gif", "image/jpeg", "image/png", "image/webp"].contains(mediaType),
      mediaType.utf8.count <= 256
    else {
      throw OpenAIResponsesProviderError.invalidRequest
    }

    let imageURL = image.sourceURL.absoluteString
    guard
      !imageURL.isEmpty,
      imageURL.utf8.count <= configuration.maximumInputValueBytes,
      let scheme = image.sourceURL.scheme?.lowercased()
    else {
      throw OpenAIResponsesProviderError.invalidRequest
    }

    switch scheme {
    case "https":
      guard
        image.sourceURL.host != nil,
        image.sourceURL.user == nil,
        image.sourceURL.password == nil
      else {
        throw OpenAIResponsesProviderError.invalidRequest
      }
    case "data":
      let prefix = "data:\(mediaType);base64,"
      guard imageURL.hasPrefix(prefix) else {
        throw OpenAIResponsesProviderError.invalidRequest
      }
      let payload = String(imageURL.dropFirst(prefix.count))
      guard
        !payload.isEmpty,
        payload.utf8.allSatisfy({ byte in
          (0x30...0x39).contains(byte)
            || (0x41...0x5A).contains(byte)
            || (0x61...0x7A).contains(byte)
            || byte == 0x2B
            || byte == 0x2F
            || byte == 0x3D
        }),
        Data(base64Encoded: payload) != nil
      else {
        throw OpenAIResponsesProviderError.invalidRequest
      }
    default:
      throw OpenAIResponsesProviderError.invalidRequest
    }
    return imageURL
  }

  private func mapTools(_ tools: [ToolDefinition]) throws -> [JSONValue] {
    tools.map { tool in
      .object([
        "type": .string("function"),
        "name": .string(tool.name),
        "description": .string(tool.description),
        "parameters": .object(tool.inputSchema),
      ])
    }
  }

  private func mapToolChoice(_ choice: ToolChoice) throws -> JSONValue {
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

  private func validateToolCall(_ call: ToolCall) throws {
    guard
      isValidIdentifier(call.id.rawValue),
      isValidToolName(call.name),
      OpenAIJSONValidator.measuredBytes(
        for: .object(call.arguments),
        maximumDepth: configuration.maximumJSONDepth,
        maximumNodes: configuration.maximumJSONNodes,
        maximumStringBytes: configuration.maximumToolArgumentBytes
      ) != nil
    else {
      throw OpenAIResponsesProviderError.invalidRequest
    }
  }

  private func encodeJSONObject(_ object: [String: JSONValue]) throws -> String {
    try encodeJSON(.object(object))
  }

  private func encodeJSON(_ value: JSONValue) throws -> String {
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

  private func isValidToolName(_ value: String) -> Bool {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= 64 else { return false }
    return bytes.allSatisfy { byte in
      (0x30...0x39).contains(byte)
        || (0x41...0x5A).contains(byte)
        || (0x61...0x7A).contains(byte)
        || byte == 0x5F
        || byte == 0x2D
    }
  }

  private func isValidIdentifier(_ value: String) -> Bool {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= configuration.maximumIdentifierBytes else {
      return false
    }
    return bytes.allSatisfy { byte in
      byte >= 0x21 && byte <= 0x7E
    }
  }

  private func addToInputBudget(_ amount: Int, total: inout Int) throws {
    let (newTotal, overflowed) = total.addingReportingOverflow(amount)
    guard !overflowed, newTotal <= configuration.maximumRequestBodyBytes else {
      throw OpenAIResponsesProviderError.invalidRequest
    }
    total = newTotal
  }
}
