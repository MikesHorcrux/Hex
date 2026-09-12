import Foundation
import HexCore

struct OpenAIResponsesInputValidator: Sendable {
  let configuration: OpenAIResponsesConfiguration

  func reasoningEffort(
    for request: InferenceRequest,
    model: ModelDescriptor
  ) throws -> String {
    if let requested = request.options.reasoningEffort {
      if let supported = model.supportedReasoningEfforts, !supported.contains(requested) {
        throw OpenAIResponsesProviderError.invalidRequest
      }
      return requested.rawValue
    }
    let configured = configuration.reasoningEffort.rawValue
    guard let supported = model.supportedReasoningEfforts else { return configured }
    if supported.contains(where: { $0.rawValue == configured }) { return configured }
    if let preferred = model.defaultReasoningEffort, supported.contains(preferred) {
      return preferred.rawValue
    }
    guard let first = supported.first else {
      throw OpenAIResponsesProviderError.invalidRequest
    }
    return first.rawValue
  }

  func validateRequestShape(
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
    if request.options.reasoningEffort != nil,
      !model.capabilities.contains(.reasoningSummary),
      model.supportedReasoningEfforts?.isEmpty != false
    {
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
      guard configuration.service == .platformAPI else {
        // The subscription endpoint rejects this API-only field. An explicit caller request
        // must fail locally rather than silently losing its promised server output constraint.
        throw OpenAIResponsesProviderError.unsupportedOutputTokenLimit
      }
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

  func validatedImageURL(_ image: ImageContent) throws -> String {
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

  func validateToolCall(_ call: ToolCall) throws {
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

  func isValidToolName(_ value: String) -> Bool {
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

  func isValidIdentifier(_ value: String) -> Bool {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= configuration.maximumIdentifierBytes else {
      return false
    }
    return bytes.allSatisfy { byte in
      byte >= 0x21 && byte <= 0x7E
    }
  }

  func addToInputBudget(_ amount: Int, total: inout Int) throws {
    let (newTotal, overflowed) = total.addingReportingOverflow(amount)
    guard !overflowed, newTotal <= configuration.maximumRequestBodyBytes else {
      throw OpenAIResponsesProviderError.invalidRequest
    }
    total = newTotal
  }
}
