import Foundation
import HexCore

@testable import HexProviders

struct OpenAIResponsesTestFixture {
  static func model() -> ModelDescriptor {
    ModelDescriptor(
      id: ModelID(rawValue: "gpt-test"),
      providerID: ProviderID(rawValue: "openai"),
      displayName: "GPT Test",
      capabilities: [
        .textInput,
        .imageInput,
        .streaming,
        .toolCalling,
        .parallelToolCalling,
        .reasoningSummary,
      ],
      contextWindow: 32_000,
      maxOutputTokens: 4_096
    )
  }

  static func configuration(
    privacyMode: OpenAIResponsesPrivacyMode = .serverManagedContinuation,
    maximumInputValueBytes: Int = 8 * 1_024 * 1_024,
    maximumRequestBodyBytes: Int = 16 * 1_024 * 1_024,
    maximumSSELineBytes: Int = 64 * 1_024,
    maximumSSEEventBytes: Int = 8 * 1_024 * 1_024,
    maximumResponseBytes: Int = 32 * 1_024 * 1_024,
    maximumStreamEvents: Int = 50_000,
    maximumToolArgumentBytes: Int = 1 * 1_024 * 1_024,
    maximumLocalStates: Int = 16,
    maximumLocalStateBytes: Int = 16 * 1_024 * 1_024,
    maximumLocalCacheBytes: Int = 64 * 1_024 * 1_024
  ) throws -> OpenAIResponsesConfiguration {
    try OpenAIResponsesConfiguration(
      endpoint: URL(string: "https://api.openai.com/v1/responses"),
      models: [model()],
      privacyMode: privacyMode,
      maximumInputValueBytes: maximumInputValueBytes,
      maximumRequestBodyBytes: maximumRequestBodyBytes,
      maximumSSELineBytes: maximumSSELineBytes,
      maximumSSEEventBytes: maximumSSEEventBytes,
      maximumResponseBytes: maximumResponseBytes,
      maximumStreamEvents: maximumStreamEvents,
      maximumToolArgumentBytes: maximumToolArgumentBytes,
      maximumLocalStates: maximumLocalStates,
      maximumLocalStateBytes: maximumLocalStateBytes,
      maximumLocalCacheBytes: maximumLocalCacheBytes
    )
  }

  static func request(
    previousResponseID: String? = nil,
    messages: [Message]? = nil,
    tools: [ToolDefinition] = [],
    toolChoice: ToolChoice = .automatic,
    options: InferenceOptions = InferenceOptions()
  ) -> InferenceRequest {
    InferenceRequest(
      providerID: ProviderID(rawValue: "openai"),
      modelID: ModelID(rawValue: "gpt-test"),
      previousProviderResponseID: previousResponseID,
      messages: messages ?? [Message(role: .user, content: [.text("Hello")])],
      tools: tools,
      toolChoice: toolChoice,
      options: options
    )
  }

  static func response(
    data: Data,
    statusCode: Int = 200,
    contentType: String? = "text/event-stream; charset=utf-8",
    splitAt offsets: [Int] = []
  ) -> OpenAIResponsesTransportResponse {
    let chunks = split(data, at: offsets)
    return OpenAIResponsesTransportResponse(
      statusCode: statusCode,
      contentType: contentType,
      body: AsyncThrowingStream { continuation in
        for chunk in chunks {
          continuation.yield(chunk)
        }
        continuation.finish()
      },
      cancel: {},
      waitForTermination: {}
    )
  }

  static func textStream(
    responseID: String = "resp_text",
    text: String = "Hello",
    lineEnding: String = "\n",
    decorateDelta: Bool = false,
    annotation: [String: Any]? = nil,
    refusal: Bool = false,
    terminalStatus: String = "completed",
    incompleteReason: String? = nil
  ) throws -> Data {
    let annotations: [[String: Any]] = annotation.map { [$0] } ?? []
    let partType = refusal ? "refusal" : "output_text"
    let valueKey = refusal ? "refusal" : "text"
    let deltaEventType = refusal ? "response.refusal.delta" : "response.output_text.delta"
    let doneEventType = refusal ? "response.refusal.done" : "response.output_text.done"
    var completedContent: [String: Any] = ["type": partType, valueKey: text]
    var addedPart: [String: Any] = ["type": partType, valueKey: ""]
    var completedPart: [String: Any] = ["type": partType, valueKey: text]
    if !refusal {
      completedContent["annotations"] = annotations
      addedPart["annotations"] = []
      completedPart["annotations"] = annotations
    }
    let item: [String: Any] = [
      "id": "msg_1",
      "type": "message",
      "status": terminalStatus,
      "role": "assistant",
      "content": [completedContent],
    ]
    let addedItem: [String: Any] = [
      "id": "msg_1",
      "type": "message",
      "status": "in_progress",
      "role": "assistant",
      "content": [],
    ]

    var data = Data()
    try appendEvent(
      [
        "type": "response.created",
        "sequence_number": 0,
        "response": ["id": responseID, "status": "in_progress"],
      ],
      to: &data,
      lineEnding: lineEnding
    )
    try appendEvent(
      [
        "type": "response.output_item.added",
        "sequence_number": 1,
        "output_index": 0,
        "item": addedItem,
      ],
      to: &data,
      lineEnding: lineEnding
    )
    try appendEvent(
      [
        "type": "response.content_part.added",
        "sequence_number": 2,
        "item_id": "msg_1",
        "output_index": 0,
        "content_index": 0,
        "part": addedPart,
      ],
      to: &data,
      lineEnding: lineEnding
    )
    try appendEvent(
      [
        "type": deltaEventType,
        "sequence_number": 3,
        "item_id": "msg_1",
        "output_index": 0,
        "content_index": 0,
        "delta": text,
      ],
      to: &data,
      lineEnding: lineEnding,
      eventName: decorateDelta ? deltaEventType : nil,
      comment: decorateDelta ? "keepalive" : nil,
      splitDataLine: decorateDelta
    )
    if let annotation, !refusal {
      try appendEvent(
        [
          "type": "response.output_text.annotation.added",
          "sequence_number": 4,
          "item_id": "msg_1",
          "output_index": 0,
          "content_index": 0,
          "annotation_index": 0,
          "annotation": annotation,
        ],
        to: &data,
        lineEnding: lineEnding
      )
    }
    let annotationOffset = annotation != nil && !refusal ? 1 : 0
    try appendEvent(
      [
        "type": doneEventType,
        "sequence_number": 4 + annotationOffset,
        "item_id": "msg_1",
        "output_index": 0,
        "content_index": 0,
        valueKey: text,
      ],
      to: &data,
      lineEnding: lineEnding
    )
    try appendEvent(
      [
        "type": "response.content_part.done",
        "sequence_number": 5 + annotationOffset,
        "item_id": "msg_1",
        "output_index": 0,
        "content_index": 0,
        "part": completedPart,
      ],
      to: &data,
      lineEnding: lineEnding
    )
    try appendEvent(
      [
        "type": "response.output_item.done",
        "sequence_number": 6 + annotationOffset,
        "output_index": 0,
        "item": item,
      ],
      to: &data,
      lineEnding: lineEnding
    )
    var terminalResponse: [String: Any] = [
      "id": responseID,
      "status": terminalStatus,
      "output": [item],
      "usage": [
        "input_tokens": 12,
        "output_tokens": 3,
        "input_tokens_details": ["cached_tokens": 2],
        "output_tokens_details": ["reasoning_tokens": 1],
      ],
    ]
    if let incompleteReason {
      terminalResponse["incomplete_details"] = ["reason": incompleteReason]
    }
    try appendEvent(
      [
        "type": terminalStatus == "incomplete" ? "response.incomplete" : "response.completed",
        "sequence_number": 7 + annotationOffset,
        "response": terminalResponse,
      ],
      to: &data,
      lineEnding: lineEnding
    )
    data.append(Data("data: [DONE]\(lineEnding)\(lineEnding)".utf8))
    return data
  }

  static func toolStream(
    responseID: String,
    callID: String,
    toolName: String = "lookup_weather",
    arguments: String = "{\"city\":\"Zürich\"}",
    includeReasoning: Bool = true
  ) throws -> Data {
    let reasoningItemID = "rs_\(responseID)"
    let functionItemID = "fc_\(responseID)"
    let reasoningAdded: [String: Any] = [
      "id": reasoningItemID,
      "type": "reasoning",
      "summary": [],
    ]
    let reasoningDone: [String: Any] = [
      "id": reasoningItemID,
      "type": "reasoning",
      "summary": [["type": "summary_text", "text": "Checking weather"]],
      "encrypted_content": "encrypted-state",
      "status": "completed",
    ]
    let callAdded: [String: Any] = [
      "id": functionItemID,
      "type": "function_call",
      "call_id": callID,
      "name": toolName,
      "arguments": "",
      "status": "in_progress",
    ]
    let callDone: [String: Any] = [
      "id": functionItemID,
      "type": "function_call",
      "call_id": callID,
      "name": toolName,
      "arguments": arguments,
      "status": "completed",
    ]

    var data = Data()
    var sequence = 0
    try appendEvent(
      [
        "type": "response.created",
        "sequence_number": sequence,
        "response": ["id": responseID, "status": "in_progress"],
      ],
      to: &data
    )
    sequence += 1

    if includeReasoning {
      try appendEvent(
        [
          "type": "response.output_item.added",
          "sequence_number": sequence,
          "output_index": 0,
          "item": reasoningAdded,
        ],
        to: &data
      )
      sequence += 1
      try appendEvent(
        [
          "type": "response.reasoning_summary_part.added",
          "sequence_number": sequence,
          "item_id": reasoningItemID,
          "output_index": 0,
          "summary_index": 0,
          "part": ["type": "summary_text", "text": ""],
        ],
        to: &data
      )
      sequence += 1
      try appendEvent(
        [
          "type": "response.reasoning_summary_text.delta",
          "sequence_number": sequence,
          "item_id": reasoningItemID,
          "output_index": 0,
          "summary_index": 0,
          "delta": "Checking weather",
        ],
        to: &data
      )
      sequence += 1
      try appendEvent(
        [
          "type": "response.reasoning_summary_text.done",
          "sequence_number": sequence,
          "item_id": reasoningItemID,
          "output_index": 0,
          "summary_index": 0,
          "text": "Checking weather",
        ],
        to: &data
      )
      sequence += 1
      try appendEvent(
        [
          "type": "response.reasoning_summary_part.done",
          "sequence_number": sequence,
          "item_id": reasoningItemID,
          "output_index": 0,
          "summary_index": 0,
          "part": ["type": "summary_text", "text": "Checking weather"],
        ],
        to: &data
      )
      sequence += 1
      try appendEvent(
        [
          "type": "response.output_item.done",
          "sequence_number": sequence,
          "output_index": 0,
          "item": reasoningDone,
        ],
        to: &data
      )
      sequence += 1
    }

    let callOutputIndex = includeReasoning ? 1 : 0
    try appendEvent(
      [
        "type": "response.output_item.added",
        "sequence_number": sequence,
        "output_index": callOutputIndex,
        "item": callAdded,
      ],
      to: &data
    )
    sequence += 1

    let argumentBytes = Array(arguments.utf8)
    let splitIndex = max(1, argumentBytes.count / 2)
    let firstDelta = String(decoding: argumentBytes[..<splitIndex], as: UTF8.self)
    let secondDelta = String(decoding: argumentBytes[splitIndex...], as: UTF8.self)
    for delta in [firstDelta, secondDelta] {
      try appendEvent(
        [
          "type": "response.function_call_arguments.delta",
          "sequence_number": sequence,
          "item_id": functionItemID,
          "output_index": callOutputIndex,
          "delta": delta,
        ],
        to: &data
      )
      sequence += 1
    }
    try appendEvent(
      [
        "type": "response.function_call_arguments.done",
        "sequence_number": sequence,
        "item_id": functionItemID,
        "output_index": callOutputIndex,
        "call_id": callID,
        "name": toolName,
        "arguments": arguments,
      ],
      to: &data
    )
    sequence += 1
    try appendEvent(
      [
        "type": "response.output_item.done",
        "sequence_number": sequence,
        "output_index": callOutputIndex,
        "item": callDone,
      ],
      to: &data
    )
    sequence += 1

    let output: [Any] = includeReasoning ? [reasoningDone, callDone] : [callDone]
    try appendEvent(
      [
        "type": "response.completed",
        "sequence_number": sequence,
        "response": [
          "id": responseID,
          "status": "completed",
          "output": output,
          "usage": [
            "input_tokens": 20,
            "output_tokens": 8,
            "input_tokens_details": ["cached_tokens": 4],
            "output_tokens_details": ["reasoning_tokens": 5],
          ],
        ],
      ],
      to: &data
    )
    data.append(Data("data: [DONE]\n\n".utf8))
    return data
  }

  static func appendEvent(
    _ object: [String: Any],
    to data: inout Data,
    lineEnding: String = "\n",
    eventName: String? = nil,
    comment: String? = nil,
    splitDataLine: Bool = false
  ) throws {
    let jsonData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard let json = String(data: jsonData, encoding: .utf8) else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    if let comment {
      data.append(Data(": \(comment)\(lineEnding)".utf8))
    }
    if let eventName {
      data.append(Data("event: \(eventName)\(lineEnding)".utf8))
    }
    if splitDataLine, let comma = json.firstIndex(of: ",") {
      let next = json.index(after: comma)
      data.append(Data("data: \(json[..<next])\(lineEnding)".utf8))
      data.append(Data("data: \(json[next...])\(lineEnding)".utf8))
    } else {
      data.append(Data("data: \(json)\(lineEnding)".utf8))
    }
    data.append(Data(lineEnding.utf8))
  }

  static func jsonObject(from request: URLRequest) throws -> [String: Any] {
    guard let body = request.httpBody else {
      throw OpenAIResponsesProviderError.invalidRequest
    }
    guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
      throw OpenAIResponsesProviderError.invalidRequest
    }
    return object
  }

  static func collect(
    provider: OpenAIResponsesProvider,
    request: InferenceRequest
  ) async throws -> [InferenceStreamEvent] {
    let stream = try await provider.stream(request)
    return try await stream.consume { cursor in
      var events: [InferenceStreamEvent] = []
      while let event = try await cursor.next() {
        events.append(event)
      }
      return events
    }
  }

  static func split(_ data: Data, at offsets: [Int]) -> [Data] {
    let validOffsets = offsets.filter { $0 > 0 && $0 < data.count }.sorted()
    var chunks: [Data] = []
    var start = data.startIndex
    for offset in validOffsets {
      let end = data.index(data.startIndex, offsetBy: offset)
      guard end > start else { continue }
      chunks.append(data[start..<end])
      start = end
    }
    if start < data.endIndex {
      chunks.append(data[start..<data.endIndex])
    }
    return chunks
  }
}
